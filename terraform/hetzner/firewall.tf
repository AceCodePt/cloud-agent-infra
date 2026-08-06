# The repo's security posture, in Hetzner terms: NO public ingress.
#
# Hetzner's documented default for an applied firewall: "If you do not set any
# rule, all inbound traffic will automatically be blocked and all outbound
# traffic will automatically be permitted." The firewall is stateful, so
# established replies come back. So an EMPTY rule set is exactly the posture:
# nothing in, everything out — Tailscale dials out and nothing else can reach
# the box.
resource "hcloud_firewall" "agent" {
  name = "${var.instance_name}-firewall"
}
