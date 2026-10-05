# The repo's security posture, in Vultr terms: no public ingress EXCEPT
# Tailscale's WireGuard port, so the box is reachable DIRECTLY (not via DERP).
#
# Vultr firewall groups are default-deny for inbound once attached: only the
# rules below are permitted and everything else is dropped; outbound is always
# allowed. An instance with NO firewall group attached has no inbound filtering
# at all, so attaching this group is the security boundary — verify asserts it.
resource "vultr_firewall_group" "agent" {
  description = "${var.instance_name}-firewall"
}

# Tailscale WireGuard, IPv4 — the direct path.
resource "vultr_firewall_rule" "tailscale_v4" {
  firewall_group_id = vultr_firewall_group.agent.id
  protocol          = "udp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "41641"
  notes             = "Tailscale WireGuard (direct)"
}

# Tailscale WireGuard, IPv6 — the direct path on v6.
resource "vultr_firewall_rule" "tailscale_v6" {
  firewall_group_id = vultr_firewall_group.agent.id
  protocol          = "udp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "41641"
  notes             = "Tailscale WireGuard (direct, v6)"
}
