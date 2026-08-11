#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

DURATION="${IPERF3_DURATION:-5}"
PORT="${IPERF3_PORT:-5201}"
PARALLEL="${IPERF3_PARALLEL:-4}"

command -v iperf3 >/dev/null 2>&1 ||
  die "iperf3 is not installed here. Install it (dnf/apt/brew install iperf3)."

note "checking $INSTANCE is reachable and has iperf3"
ssh_vm 'command -v iperf3 >/dev/null 2>&1' ||
  die "iperf3 is not installed on $INSTANCE (install with: dnf install iperf3)"

TS_IP="$(ssh_vm 'tailscale ip -4' 2>/dev/null | tr -d ' \n' | head -1)"
[[ -n "$TS_IP" ]] || die "could not read $INSTANCE's Tailscale IPv4"

UNIT="iperf3-$$"
PORT_OPENED=""
cleanup() {
  if [[ -n "$PORT_OPENED" ]]; then
    ssh_vm "sudo firewall-cmd --remove-port=$PORT/tcp" >/dev/null 2>&1 || true
  fi
  ssh_vm "sudo systemctl stop $UNIT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# firewalld on the box only allows TCP 22 (Tailscale SSH); the iperf3 port must
# be opened for the run and closed after. Runtime-only (not --permanent), and
# the server binds the Tailscale IP, so nothing public is exposed.
note "opening port $PORT/tcp on $INSTANCE (closes when the test finishes)"
ssh_vm "sudo firewall-cmd --add-port=$PORT/tcp" >/dev/null 2>&1 &&
  PORT_OPENED=1

note "starting iperf3 server on $INSTANCE ($TS_IP:$PORT)"
ssh_vm "sudo systemd-run --unit=$UNIT --collect /usr/bin/iperf3 -s -p $PORT -B $TS_IP" >/dev/null 2>&1 ||
  die "could not start the iperf3 server on $INSTANCE"

ready=false
for _ in $(seq 1 20); do
  if timeout 2 bash -c "exec 3<>/dev/tcp/$TS_IP/$PORT" 2>/dev/null; then
    ready=true
    break
  fi
  sleep 0.5
done
$ready || die "iperf3 server on $TS_IP:$PORT never became reachable"

printf '\n\033[1mConnection speed %s <-> %s  (%s:%s, %ss, %s parallel streams)\033[0m\n' \
  "$HOSTNAME" "$INSTANCE" "$TS_IP" "$PORT" "$DURATION" "$PARALLEL"

rate() { # rate <sent|recv> — reads iperf3 -J JSON on stdin, prints Mbits/s
  python3 -c '
import json, sys
key, d = sys.argv[1], json.load(sys.stdin)
end = d.get("end", {})
sent = (end.get("sum_sent") or {}).get("bits_per_second", 0)
recv = (end.get("sum_received") or {}).get("bits_per_second", 0)
v = sent if key == "sent" else recv
print("%.1f" % (v / 1e6))
if key == "sent":
    retrans = (end.get("sum_sent") or {}).get("retransmits", 0)
    print("retrans=%d" % retrans, file=sys.stderr)
' "$1"
}

UP_RETRANS="$(mktemp)"
echo
echo "  >> upload   (this machine -> $INSTANCE)"
UP="$(iperf3 -c "$TS_IP" -p "$PORT" -P "$PARALLEL" -t "$DURATION" -J 2>/dev/null | rate sent 2>"$UP_RETRANS")" ||
  { rm -f "$UP_RETRANS"; die "upload test failed"; }
printf '     %s Mbits/sec' "$UP"
if [[ -s "$UP_RETRANS" ]]; then
  printf '  (%s)' "$(grep -o 'retrans=[0-9]*' "$UP_RETRANS")"
fi
printf '\n'
rm -f "$UP_RETRANS"

echo
echo "  >> download ($INSTANCE -> this machine)"
DOWN="$(iperf3 -c "$TS_IP" -p "$PORT" -P "$PARALLEL" -t "$DURATION" -R -J 2>/dev/null | rate recv)" ||
  die "download test failed"
printf '     %s Mbits/sec\n' "$DOWN"

# --- why it is (not) fast: path, latency, and the addressing facts behind it ---

PING="$(timeout 12 tailscale ping -c 3 "$INSTANCE" 2>&1 || true)"
if [[ "$PING" == *"via DERP"* ]]; then
  DERP="$(grep -oE 'DERP\([^)]*\)' <<<"$PING" | head -1)"
  RTT="$(grep -oE 'in [0-9]+ms' <<<"$PING" | head -1 | tr -dc '0-9')"
  DIRECT=false
elif [[ "$PING" == *"pong"* ]]; then
  RTT="$(grep -oE 'in [0-9]+ms' <<<"$PING" | head -1 | tr -dc '0-9')"
  DIRECT=true
else
  RTT=""
  DIRECT=""
fi

# First global address NOT on the tailscale interface. `ip` prints the device
# name on its own line, so a plain `grep -v tailscale` cannot filter address
# lines; track the interface per block instead. (fe80 is link-local, never
# scope global, so it is already excluded.)
first_global_v6() {
  ip -6 addr show scope global 2>/dev/null | awk '
    /^[0-9]+: / { dev=$2; sub(/:$/, "", dev) }
    /inet6/ && dev != "tailscale0" { print $2; exit }'
}
LOCAL_V6="$(first_global_v6)"
REMOTE_V6="$(ssh_vm "export PATH=/usr/local/sbin:/usr/sbin:/sbin:\$PATH; $(declare -f first_global_v6); first_global_v6" 2>/dev/null || true)"

echo
echo "  >> path"
if [[ "$DIRECT" == true ]]; then
  echo "     direct WireGuard link (RTT ~${RTT:-?} ms) — not relayed"
else
  echo "     DERP relay ${DERP:-<unknown>} (RTT ~${RTT:-?} ms) — NOT a direct link"
fi

echo
echo "  >> insight"
if [[ "$DIRECT" == true ]]; then
  echo "     The link is direct, so these are the real wire numbers. If they are"
  echo "     still low, the bottleneck is closer to home: local Wi-Fi, the ISP"
  echo "     uplink, or the OCI NAT gateway."
else
  echo "     This is why it is slow: the packet is being RELAYED, not sent direct."
  echo "     A DERP relay re-encrypts and re-packetizes every byte over its own"
  echo "     uplink, so throughput is capped by the relay plus a long detour."
  echo "     There is no direct path because no address family is routable end"
  echo "     to end between the two sides:"
  if [[ -z "$LOCAL_V6" ]]; then
    echo "       - this machine has NO global IPv6 (its network is IPv4-only)"
  else
    echo "       - this machine has global IPv6 (${LOCAL_V6%%/*})"
  fi
  if [[ -z "$REMOTE_V6" ]]; then
    echo "       - the box has NO global IPv6"
  else
    echo "       - the box has global IPv6 (${REMOTE_V6%%/*})"
  fi
  echo "       - the box has no public IPv4 (private OCI VNIC, by design)"
  echo "     Fix: get IPv6 on this network (router/ISP). Tailscale will then take"
  echo "     the direct IPv6 path and this test should jump orders of magnitude."
fi
