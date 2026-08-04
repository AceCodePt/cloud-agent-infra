#!/usr/bin/env node
// Drive K concurrent canary tasks against a running opencode server.
//
// The canary is a bounded, self-terminating task: read src/compiler/checker.ts
// and list functions. It exercises the same stack a real client does -- read
// tool, shared tsgo LSP, model stream -- but finishes, so "did it complete?"
// is a yes/no answer per round. A box that halts stops completing; a box that
// is merely slow completes, late.
//
// Records every round as ok/err so provider throttling (a 429 or upstream
// error) can be told apart from the box halting. Those are different findings.
//
//   node agent-stress.mjs <K> <rounds> [canary prompt]
import { request } from "node:http";

const K = Number(process.argv[2]);
const ROUNDS = Number(process.argv[3]);
const CANARY =
  process.argv.slice(4).join(" ") ||
  "Read src/compiler/checker.ts and list 5 functions that type-check AST nodes, with their line numbers.";

if (!K || !ROUNDS) {
  console.error("usage: agent-stress.mjs <K> <rounds> [prompt]");
  process.exit(64);
}

const HOST = "127.0.0.1";
const PORT = 4098;
const AUTH = Buffer.from("opencode:x").toString("base64");

function http(method, path, body) {
  return new Promise((resolve, reject) => {
    const req = request(
      {
        method,
        host: HOST,
        port: PORT,
        path,
        headers: {
          Authorization: `Basic ${AUTH}`,
          ...(body ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) } : {}),
        },
      },
      (res) => {
        let buf = "";
        res.on("data", (d) => (buf += d));
        res.on("end", () => resolve({ status: res.statusCode, body: buf }));
      },
    );
    req.on("error", reject);
    if (body) req.end(body);
    else req.end();
  });
}

async function health() {
  try {
    const r = await http("GET", "/global/health");
    return r.status === 200;
  } catch {
    return false;
  }
}

async function createSession() {
  const body = JSON.stringify({ agent: "build", model: { id: "big-pickle", providerID: "opencode" } });
  const r = await http("POST", "/api/session", body);
  if (r.status !== 200) throw new Error(`session create: ${r.status} ${r.body.slice(0, 120)}`);
  return JSON.parse(r.body).data.id;
}

// One canary = ROUNDS sequential rounds on one session. Sequential within a
// session (that is how a client works); parallel across sessions.
async function canary(sid, k) {
  const rounds = [];
  for (let r = 0; r < ROUNDS; r++) {
    const t0 = Date.now();
    let outcome = "err";
    try {
      const res = await http(
        "POST",
        `/session/${sid}/message`,
        JSON.stringify({
          agent: "build",
          model: { providerID: "opencode", modelID: "big-pickle" },
          parts: [{ type: "text", text: CANARY }],
        }),
      );
      if (res.status !== 200) {
        outcome = `err:http${res.status}`;
      } else {
        const j = JSON.parse(res.body);
        outcome = (j.parts || []).some((p) => p.type === "text" && p.text.trim().length > 20) ? "ok" : "err:empty";
      }
    } catch (e) {
      outcome = `err:${e.code || e.message}`;
    }
    rounds.push({ round: r + 1, outcome, ms: Date.now() - t0 });
    process.stdout.write(`K${k} r${r + 1} ${outcome} ${((Date.now() - t0) / 1000).toFixed(1)}s\n`);
  }
  return rounds;
}

const tStart = Date.now();
console.log(`starting ${K} concurrent canaries x ${ROUNDS} rounds on ${HOST}:${PORT}`);
if (!(await health())) {
  console.error("server not healthy at start");
  process.exit(1);
}

const sessions = [];
for (let k = 0; k < K; k++) sessions.push(await createSession());

const results = await Promise.all(sessions.map((sid, i) => canary(sid, i + 1)));
const flat = results.flat();
const ok = flat.filter((r) => r.outcome === "ok").length;
const errs = flat.filter((r) => r.outcome.startsWith("err"));

// Any /global/health probe mid-run failing = the server itself went away.
const aliveAtEnd = await health();
const aliveNow = await health();
const elapsed = ((Date.now() - tStart) / 1000).toFixed(0);

console.log("\n=== SUMMARY ===");
console.log(`sessions: ${K}, rounds/session: ${ROUNDS}, total: ${flat.length}`);
console.log(`ok: ${ok}  err: ${errs.length}  completion: ${((ok / flat.length) * 100).toFixed(0)}%`);
console.log(`server healthy: at-start=yes  mid-run=${aliveAtEnd}  end=${aliveNow}`);
console.log(`elapsed: ${elapsed}s`);
if (errs.length) {
  const kinds = {};
  for (const e of errs) kinds[e.outcome] = (kinds[e.outcome] || 0) + 1;
  console.log(`error kinds: ${JSON.stringify(kinds)}`);
}
if (ok > 0) {
  const okms = flat.filter((r) => r.outcome === "ok").map((r) => r.ms);
  console.log(
    `ok round times: min ${Math.round(Math.min(...okms) / 1000)}s  median ${Math.round(okms.sort((a, b) => a - b)[Math.floor(okms.length / 2)] / 1000)}s  max ${Math.round(Math.max(...okms) / 1000)}s`,
  );
}
process.exit(0);