# network.tf
#
# Dedicated VPC for the agent box, with a locked-down firewall.
#
# Security posture:
#   - NO public inbound. The internet cannot reach the VM on any port.
#   - Access is exclusively via:
#       * Tailscale  (outbound-only; needs zero inbound rules)
#       * gcloud compute ssh over IAP (Google's control-plane tunnel)
#   - Egress is allowed so Tailscale/apt/git can reach out.
#
# We use our OWN network instead of the "default" one specifically to avoid
# GCP's auto-created default-allow-ssh / -rdp / -icmp rules, which open
# tcp:22, tcp:3389, and icmp to 0.0.0.0/0 on the default network.

resource "google_compute_network" "agent" {
  name                    = "${var.instance_name}-net"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "agent" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.agent.id
}

# Allow SSH from Google's IAP range ONLY (for `gcloud compute ssh`).
# This is the narrow, safe replacement for default-allow-ssh (0.0.0.0/0).
# IAP source range is a fixed Google-owned block.
resource "google_compute_firewall" "iap_ssh" {
  name      = "${var.instance_name}-allow-iap-ssh"
  network   = google_compute_network.agent.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Google Identity-Aware Proxy range. Traffic from your laptop via
  # `gcloud compute ssh` is proxied through here, not from your real IP.
  source_ranges = ["35.235.240.0/20"]
}

# Allow traffic within the subnet (VM<->VM if you ever add more).
resource "google_compute_firewall" "internal" {
  name      = "${var.instance_name}-allow-internal"
  network   = google_compute_network.agent.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.10.0.0/24"]
}

# Explicit egress allow (Tailscale dials out; apt/git need internet).
resource "google_compute_firewall" "egress" {
  name      = "${var.instance_name}-allow-egress"
  network   = google_compute_network.agent.name
  direction = "EGRESS"

  allow {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
}

# NOTE: There is deliberately NO public ingress rule — not for SSH, not for
# anything. You reach the VM over the Tailscale tailnet, which is established
# outbound, so it needs zero inbound rules. Nothing on the public internet
# can reach the box.
