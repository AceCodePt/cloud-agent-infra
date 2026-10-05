locals {
  # Vultr block storage attaches as a virtio disk; /dev/vdb is the first data
  # disk after the boot disk (/dev/vda). startup.rhel.sh also falls back to
  # /dev/sdb and to by-label discovery, so this is only the first guess.
  data_dev = "/dev/vdb"

  # startup.rhel.sh is the single RHEL-family template shared by every provider
  # (OCI boots Oracle Linux, Hetzner and Vultr boot Rocky Linux 9; the setup
  # process after image selection is identical).
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

# Vultr startup scripts take a base64 payload (up to 64 KB) and run at boot.
# The rendered script is ~35 KB / ~47 KB base64: too big for user_data's cap,
# but comfortable here — and unlike user_data it stays as a named, inspectable
# account object.
resource "vultr_startup_script" "agent" {
  name   = "${var.instance_name}-startup"
  type   = "boot"
  script = base64encode(local.startup_script)
}

resource "vultr_instance" "agent" {
  region            = var.region
  plan              = var.machine_type
  os_id             = var.os_id
  label             = var.instance_name
  hostname          = var.instance_name
  enable_ipv6       = true
  activation_email  = false
  script_id         = vultr_startup_script.agent.id
  firewall_group_id = vultr_firewall_group.agent.id

  lifecycle {
    # rekey delivers keys in-guest (systemctl restart agent-startup), never via
    # the startup script — so changing the template or key must not try to
    # rebuild. (script_id is ForceNew on the instance anyway.)
    ignore_changes = [script_id]
  }
}

# Block storage for repos + tailscale state + browser profiles. Tel Aviv only
# offers the storage_opt type, which has a 40 GB floor (~$1/mo at 40 GB).
resource "vultr_block_storage" "agent" {
  label                = "${var.instance_name}-data"
  size_gb              = var.data_disk_size_gb
  region               = var.region
  block_type           = "storage_opt"
  live                 = true
  attached_to_instance = vultr_instance.agent.id
}
