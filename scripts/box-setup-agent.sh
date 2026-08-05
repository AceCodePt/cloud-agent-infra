#!/bin/bash
set -euo pipefail
pkill -f "[o]pencode serve" 2>/dev/null || true
sleep 2
pkill -f "[t]sgo --lsp" 2>/dev/null || true
sleep 1
cd /mnt/data/repos/ts
rm -f /tmp/oc-work.log
nohup setsid env OPENCODE_SERVER_PASSWORD=x opencode serve --port 4098 --hostname 127.0.0.1 >/tmp/oc-work.log 2>&1 < /dev/null &
disown
for i in $(seq 1 30); do
  if curl -sf -u opencode:x http://127.0.0.1:4098/global/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -sf -u opencode:x http://127.0.0.1:4098/global/health || { echo "server failed to start"; exit 1; }
SID=$(curl -sf -u opencode:x -X POST http://127.0.0.1:4098/api/session \
  -H "Content-Type: application/json" \
  -d '{"agent":"build","model":{"id":"big-pickle","providerID":"opencode"}}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
echo "$SID" > /tmp/agent-sid
echo "SESSION=$SID"