data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

resource "google_compute_disk" "data" {
  name = "${var.instance_name}-data"
  type = "pd-balanced"
  zone = var.zone
  size = var.data_disk_size_gb
}

resource "google_compute_instance" "agent" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 20
    }
  }

  attached_disk {
    source      = google_compute_disk.data.id
    device_name = "data"
  }

  network_interface {
    network    = google_compute_network.agent.id
    subnetwork = google_compute_subnetwork.agent.id

    access_config {}
  }

  metadata = merge(
    { startup-script = local.startup_script },
    var.ssh_public_key != "" ? { ssh-keys = "${var.ssh_user}:${var.ssh_public_key}" } : {}
  )

  tags = ["cloud-agent"]

  lifecycle {
    ignore_changes = [attached_disk]

    precondition {
      condition     = length(regexall("\\$\\$", local.startup_script)) == 0
      error_message = "startup_script still contains '$$' after rendering. In an HCL heredoc, write bare $VAR/$@/$? (a '$' not followed by '{' passes through); '$$' is an escape ONLY before '{', so '$$VAR' becomes a literal '$$' that bash expands to the PID."
    }
  }
}
