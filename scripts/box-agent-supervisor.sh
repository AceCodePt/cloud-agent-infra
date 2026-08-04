#!/bin/bash
# Supervisor: wait for the stress to finish, then SIGTERM the sampler so it
# prints its peak numbers (which are maxes over the window, so idle tail is fine).
set -uo pipefail
for i in $(seq 1 120); do
  grep -q "SUMMARY" /tmp/stress.out 2>/dev/null && break
  sleep 5
done
pkill -TERM -f "[m]easure-resources" 2>/dev/null || true
exit 0