# compute.tf — the box itself: image, persistent data disk, instance.

# Debian 12 (bookworm), built and maintained by Google and rebuilt constantly —
# the image is always fresh, so first boot has nothing to catch up on.
data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

# Separate persistent disk so repos + state survive VM recreation. It also holds
# the tailscale node identity and the notify-phone keypair, which is why
# destroying it forces a phone re-key (see scripts/provision-phone.sh).
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

  # Dedicated, locked-down network (see network.tf). No public inbound.
  network_interface {
    network    = google_compute_network.agent.id
    subnetwork = google_compute_subnetwork.agent.id

    # Ephemeral public IP: needed for Tailscale's outbound connection.
    #
    # Deliberately NOT reserved/static, though GCP does hand out a new address on
    # every stop/start (measured: 34.165.106.36 -> 34.165.192.90 across one
    # pause). A static IP was tried and reverted: the premise was that a moving
    # address would trip account-security checks on a logged-in social session,
    # and that premise does not survive contact with how people actually use
    # these services. Phones roam between home wifi, mobile data and café APs all
    # day; if a changed IP were weighted heavily, the mobile apps would be
    # unusable. The claim also had thin evidence behind it (see SPEC.md) — it
    # came mostly from proxy vendors, who sell the fix.
    access_config {}
  }

  # Native Debian: provision via a startup script (not a container).
  # The Linux Guest Environment on this image runs startup-script on boot.
  metadata = merge(
    { startup-script = local.startup_script },
    var.ssh_public_key != "" ? { ssh-keys = "${var.ssh_user}:${var.ssh_public_key}" } : {}
  )

  tags = ["cloud-agent"]

  lifecycle {
    ignore_changes = [attached_disk]

    # Guard against the HCL escaping footgun documented in startup.tf: `$$` is
    # only an escape before `{`, so `$$VAR`/`$$@` render as two literal dollars
    # and bash then expands `$$` to the PID. Nothing legitimate should survive
    # rendering as `$$`, so fail the apply instead of shipping a broken script.
    precondition {
      condition     = length(regexall("\\$\\$", local.startup_script)) == 0
      error_message = "startup_script still contains '$$' after rendering. In an HCL heredoc, write bare $VAR/$@/$? (a '$' not followed by '{' passes through); '$$' is an escape ONLY before '{', so '$$VAR' becomes a literal '$$' that bash expands to the PID."
    }
  }
}
