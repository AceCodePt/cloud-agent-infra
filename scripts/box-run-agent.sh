#!/bin/bash
# Run a long agent workload on the box in the background, logging to /tmp/agent-run.log.
set -euo pipefail
SID=$1
REPEAT=$2
PROMPT=$3
nohup setsid node /tmp/drive-agent-loop.mjs "$SID" "$REPEAT" "$PROMPT" > /tmp/agent-run.log 2>&1 < /dev/null &
disown
echo "started agent loop pid $!"