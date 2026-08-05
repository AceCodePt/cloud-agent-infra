#!/bin/bash
set -uo pipefail
K=$1
ROUNDS=$2
LABEL=${3:-"stress K=$K"}
export PATH=/usr/local/sbin:/usr/sbin:/sbin:$PATH

echo "=== $LABEL ==="

pkill -f '^/usr/local/bin/opencode serve' 2>/dev/null || true
pkill -f 'tsgo --lsp' 2>/dev/null || true
pkill -f '^/usr/bin/node /tmp/agent-stress' 2>/dev/null || true
pkill -f '^/usr/bin/python3 /tmp/measure-resources' 2>/dev/null || true
sleep 2
cd /mnt/data/repos/ts
rm -f /tmp/oc-work.log /tmp/stress.out /tmp/measure.out

nohup setsid env OPENCODE_SERVER_PASSWORD=x /usr/local/bin/opencode serve --port 4098 --hostname 127.0.0.1 >/tmp/oc-work.log 2>&1 < /dev/null &
disown

for i in $(seq 1 40); do
  curl -sf --connect-timeout 2 --max-time 3 -u opencode:x http://127.0.0.1:4098/global/health >/dev/null 2>&1 && break
  sleep 1
done
curl -sf --connect-timeout 2 --max-time 3 -u opencode:x http://127.0.0.1:4098/global/health >/dev/null 2>&1 || { echo "SERVER FAILED TO START"; exit 1; }
echo "server up"

/usr/bin/python3 /tmp/measure-resources.py --seconds 600 --interval 2 --label "$LABEL" > /tmp/measure.out 2>&1 &
SAMP_PID=$!

echo "sampler running; starting $K canaries x $ROUNDS rounds"
node /tmp/agent-stress.mjs "$K" "$ROUNDS" > /tmp/stress.out 2>&1
STRESS_RC=$?

kill -TERM "$SAMP_PID" 2>/dev/null
sleep 2

echo ""
echo "=== HALT SIGNALS ==="
echo "-- canary completion --"
tail -12 /tmp/stress.out
echo ""
echo "-- OOM killer in dmesg (sudo) --"
sudo -n dmesg 2>/dev/null | grep -iE "out of memory|oom-kill|killed process" | tail -5 || echo "  (none / dmesg restricted)"
echo ""
echo "-- processes alive at end --"
echo "  opencode: $(pgrep -cf '^/usr/local/bin/opencode serve')"
echo "  tsgo:     $(pgrep -cf 'tsgo --lsp')"
echo "-- server healthy --"
curl -sf --connect-timeout 2 --max-time 3 -u opencode:x http://127.0.0.1:4098/global/health && echo " OK" || echo " DEAD"
echo ""
echo "=== RESOURCE PEAKS (sampler window) ==="
grep -E "peak PSS total|min MemAvailable|peak swap|max 1-min" /tmp/measure.out 2>/dev/null
echo ""
echo "stress exit: $STRESS_RC"
exit $STRESS_RC