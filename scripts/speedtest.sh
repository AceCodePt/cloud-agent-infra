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
run_remote "reaching $INSTANCE over SSH" 'command -v iperf3 >/dev/null 2>&1' ||
  die "iperf3 is not installed on $INSTANCE (install with: dnf install iperf3)"

TS_IP="$(run_remote "reading $INSTANCE's Tailscale IPv4" 'tailscale ip -4')" &&
  TS_IP="${TS_IP//[$' \n']/}" ||
  die "could not read $INSTANCE's Tailscale IPv4"

UNIT="iperf3-server"
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

# start_transient reaps any stale iperf3-* unit and asserts the server is
# actually running (systemd-run alone returns 0 even on a failed bind).
note "starting iperf3 server on $INSTANCE ($TS_IP:$PORT)"
start_transient "$UNIT" 'iperf3-*' "/usr/bin/iperf3 -s -p $PORT -B $TS_IP" >/dev/null ||
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

# The box's public IPv4 (reserved public IP on the VNIC). The IPv4 route via
# the internet gateway sources egress from it, and it is the direct endpoint
# Tailscale advertises.
REMOTE_PUB4="$(ssh_vm "curl -4sf --max-time 5 https://ifconfig.me 2>/dev/null || true" 2>/dev/null || true)"

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
  echo "     still low, the bottleneck is closer to home: local Wi-Fi or the ISP"
  echo "     uplink."
else
  echo "     This is why it is slow: the packet is being RELAYED, not sent direct."
  echo "     A DERP relay re-encrypts and re-packetizes every byte over its own"
  echo "     uplink, so throughput is capped by the relay plus a long detour."
  echo "     The box has a public IPv4 (${REMOTE_PUB4:-?}) that lets it be reached"
  echo "     directly, so a relay here means this machine's network (a symmetric"
  echo "     NAT, or UDP being filtered) is blocking the direct handshake."
  if [[ -z "$LOCAL_V6" ]]; then
    echo "     There is no IPv6 path either: this machine has NO global IPv6"
    echo "     (its network is IPv4-only), while the box does have global IPv6"
    echo "     (${REMOTE_V6:-?})."
  else
    echo "     This machine has global IPv6 (${LOCAL_V6%%/*}); the box has"
    echo "     IPv6 too, so the relay is likely a transient mapping loss rather"
    echo "     than a permanent addressing gap."
  fi
  echo "     Fixes, in order of preference: move to a network that does not"
  echo "     interfere with the NAT mapping (a phone hotspot usually works), or"
  echo "     enable IPv6 on this network — either restores a direct path."
fi
