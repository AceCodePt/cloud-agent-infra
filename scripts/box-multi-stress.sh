#!/bin/bash
# Realistic stress: one opencode server PER client (the actual per-client
# isolation design), each with its own session and its own tsgo LSP, all
# reading the same shared repo. This is the honest per-client memory number.
set -uo pipefail
K=$1
ROUNDS=$2
LABEL=${3:-"multi-server K=$K"}
export PATH=/usr/local/sbin:/usr/sbin:/sbin:$PATH

echo "=== $LABEL ==="

pkill -f '^/usr/local/bin/opencode serve' 2>/dev/null || true
pkill -f 'tsgo --lsp' 2>/dev/null || true
sleep 2

rm -f /tmp/oc-work.log /tmp/stress.out /tmp/measure.out /tmp/multi-sessions

BASE=4100
for k in $(seq 1 "$K"); do
  PORT=$((BASE + k))
  ( cd /mnt/data/repos/ts && \
    nohup setsid env OPENCODE_SERVER_PASSWORD=x /usr/local/bin/opencode serve \
      --port "$PORT" --hostname 127.0.0.1 \
      >/tmp/oc-$k.log 2>&1 < /dev/null & disown )
done
echo "launched $K servers on ports $((BASE+1))-$((BASE+K))"

for k in $(seq 1 "$K"); do
  PORT=$((BASE + k))
  for i in $(seq 1 40); do
    curl -sf --connect-timeout 2 --max-time 3 -u opencode:x "http://127.0.0.1:$PORT/global/health" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -sf --connect-timeout 2 --max-time 3 -u opencode:x "http://127.0.0.1:$PORT/global/health" >/dev/null 2>&1 || { echo "server $PORT FAILED"; exit 1; }
  SID=$(curl -sf -u opencode:x -X POST "http://127.0.0.1:$PORT/api/session" \
    -H "Content-Type: application/json" \
    -d '{"agent":"build","model":{"id":"big-pickle","providerID":"opencode"}}' \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  echo "$PORT $SID" >> /tmp/multi-sessions
done
echo "all $K servers up with sessions"

/usr/bin/python3 /tmp/measure-resources.py --seconds 900 --interval 2 --label "$LABEL" > /tmp/measure.out 2>&1 &
SAMP_PID=$!

# Drive each server's session once, concurrently.
cat > /tmp/multi-drive.mjs <<'EOF'
import { request } from "node:http";
import { readFileSync } from "node:fs";
const CANARY = "Read src/compiler/checker.ts and list 5 functions that type-check AST nodes, with line numbers.";
const sessions = readFileSync("/tmp/multi-sessions", "utf8").trim().split("\n")
  .map((l) => l.split(" ")).map(([port, sid]) => ({ port, sid }));
function drive({ port, sid }, round) {
  return new Promise((resolve) => {
    const body = JSON.stringify({
      agent: "build",
      model: { providerID: "opencode", modelID: "big-pickle" },
      parts: [{ type: "text", text: round === 0 ? CANARY : `Continue. Round ${round + 1}. ${CANARY}` }],
    });
    const req = request({
      method: "POST", host: "127.0.0.1", port: Number(port),
      path: `/session/${sid}/message`,
      headers: { Authorization: `Basic ${Buffer.from("opencode:x").toString("base64")}`, "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    }, (res) => {
      let buf = ""; res.on("data", (d) => (buf += d));
      res.on("end", () => {
        let ok = false;
        try { const j = JSON.parse(buf); ok = (j.parts || []).some((p) => p.type === "text" && p.text.trim().length > 20); } catch {}
        process.stdout.write(`K${port - 4100} r${round + 1} ${ok ? "ok" : "err"} \n`);
        resolve(ok);
      });
    });
    req.on("error", () => { process.stdout.write(`K${port - 4100} r${round + 1} err \n`); resolve(false); });
    req.end(body);
  });
}
(async () => {
  let total = 0, ok = 0;
  for (let round = 0; round < Number(process.argv[2]); round++) {
    const rs = await Promise.all(sessions.map((s) => drive(s, round)));
    ok += rs.filter(Boolean).length; total += rs.length;
  }
  console.log(`\nMULTI SUMMARY: ${ok}/${total} rounds ok (${((ok / total) * 100).toFixed(0)}%)`);
  process.exit(0);
})();
EOF

node /tmp/multi-drive.mjs "$ROUNDS" > /tmp/stress.out 2>&1
STRESS_RC=$?

kill -TERM "$SAMP_PID" 2>/dev/null
sleep 2

echo ""
echo "=== HALT SIGNALS ==="
tail -8 /tmp/stress.out
echo ""
sudo -n dmesg 2>/dev/null | grep -iE "out of memory|oom-kill|killed process" | tail -5 || echo "  (none / dmesg restricted)"
echo ""
echo "  opencode: $(pgrep -cf '^/usr/local/bin/opencode serve')"
echo "  tsgo:     $(pgrep -cf 'tsgo --lsp')"
echo ""
echo "=== RESOURCE PEAKS ==="
grep -E "peak PSS total|min MemAvailable|peak swap|max 1-min" /tmp/measure.out 2>/dev/null
echo ""
echo "multi exit: $STRESS_RC"
exit $STRESS_RC