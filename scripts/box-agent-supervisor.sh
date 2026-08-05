#!/bin/bash
set -uo pipefail
for i in $(seq 1 120); do
  grep -q "SUMMARY" /tmp/stress.out 2>/dev/null && break
  sleep 5
done
pkill -TERM -f "[m]easure-resources" 2>/dev/null || true
exit 0