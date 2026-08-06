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

resource "google_compute_firewall" "iap_ssh" {
  name      = "${var.instance_name}-allow-iap-ssh"
  network   = google_compute_network.agent.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
}

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

resource "google_compute_firewall" "egress" {
  name      = "${var.instance_name}-allow-egress"
  network   = google_compute_network.agent.name
  direction = "EGRESS"

  allow {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
}
