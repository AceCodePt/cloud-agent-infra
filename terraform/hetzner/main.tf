locals {
  # Hetzner volumes attach as SCSI disks with a serial that embeds the volume ID.
  data_dev = "/dev/disk/by-id/scsi-0HC_Volume_${hcloud_volume.agent.id}"

  # startup.rhel.sh is the single RHEL-family template shared by every provider
  # (OCI boots Oracle Linux, Hetzner boots Rocky Linux 9; the setup process
  # after image selection is identical).
  startup_script = replace(
    replace(
      replace(
        replace(
          replace(
            file("${path.module}/../../scripts/templates/startup.rhel.sh"),
          "__DATA_DEV__", local.data_dev),
        "__DATA_LABEL__", var.data_label),
      "__INSTANCE__", var.instance_name),
    "__USER__", var.ssh_user),
    "__AUTHKEY__", var.tailscale_auth_key
  )
}

resource "hcloud_volume" "agent" {
  name     = "${var.instance_name}-data"
  size     = var.data_disk_size_gb
  location = var.location
}

resource "hcloud_server" "agent" {
  name         = var.instance_name
  server_type  = var.machine_type
  image        = "rocky-9"
  location     = var.location
  user_data    = local.startup_script
  firewall_ids = [hcloud_firewall.agent.id]

  lifecycle {
    # rekey delivers keys in-guest (systemctl restart agent-startup), never via
    # user_data — so changing the template or key must not try to rebuild.
    ignore_changes = [user_data]
  }
}

resource "hcloud_volume_attachment" "agent" {
  volume_id = hcloud_volume.agent.id
  server_id = hcloud_server.agent.id
}
