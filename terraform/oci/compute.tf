locals {
  # Default: the instance boots a throwaway Oracle Linux image that stages Arch
  # Linux on the data volume and reboots into it; startup.arch.sh does the whole
  # build. When custom_image_id is set we boot the clean golden Arch image and
  # provision it on the cloud at first boot via startup.image.sh — provisioning
  # must happen on the box, never baked into the image, so user_data is never
  # set to null.
  use_custom_image = var.custom_image_id != ""
  source_id        = local.use_custom_image ? var.custom_image_id : data.oci_core_images.oracle_linux.images[0].id
  ssh_pub          = trimspace(file(pathexpand("~/.ssh/id_ed25519.pub")))
  startup_script = replace(
    replace(
      replace(
        replace(
          replace(
            replace(
              file("${path.module}/../../scripts/templates/startup.arch.sh"),
            "__DATA_DEV__", local.data_dev),
          "__DATA_LABEL__", var.data_label),
        "__INSTANCE__", var.instance_name),
      "__USER__", var.ssh_user),
    "__AUTHKEY__", var.tailscale_auth_key),
    "__SSHPUB__", local.ssh_pub
  )

  # Custom-image first-boot provisioning (golden Arch image). Same token
  # substitutions as startup_script; rendered from startup.image.sh so the box
  # provisions itself on the cloud instead of relying on baked-in config.
  startup_custom = replace(
    replace(
      replace(
        replace(
          replace(
            replace(
              file("${path.module}/../../scripts/templates/startup.image.sh"),
            "__DATA_DEV__", local.data_dev),
          "__DATA_LABEL__", var.data_label),
        "__INSTANCE__", var.instance_name),
      "__USER__", var.ssh_user),
    "__AUTHKEY__", var.tailscale_auth_key),
    "__SSHPUB__", local.ssh_pub
  )

  # OCI paravirtualized block volumes attach as /dev/sdb (a /dev/oracleoci/
  # udev alias also appears). startup.arch.sh probes both before declaring the
  # disk missing.
  data_dev = "/dev/oracleoci/oraclevdb"
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = local.compartment
}

# Oracle Linux 9.8, aarch64. Filter for the latest arm64 image; if none is
# found the apply fails loudly instead of booting an x86 box.
data "oci_core_images" "oracle_linux" {
  compartment_id           = local.compartment
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.machine_type
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}

resource "oci_core_volume" "agent" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment
  display_name        = "${var.instance_name}-data"
  size_in_gbs         = var.data_disk_size_gb
}

resource "oci_core_volume_attachment" "agent" {
  # Paravirtualized: the device appears automatically, no iSCSI login needed.
  # Shows up as /dev/oracleoci/oraclevdb on the guest.
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.agent.id
  volume_id       = oci_core_volume.agent.id
}

resource "oci_core_instance" "agent" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment
  display_name        = var.instance_name
  shape               = var.machine_type

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.agent.id
    assign_public_ip = false
    hostname_label   = var.instance_name
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand("~/.ssh/id_ed25519.pub"))
    user_data           = base64encode(local.use_custom_image ? local.startup_custom : local.startup_script)
  }

  source_details {
    source_type             = "image"
    source_id               = local.source_id
    boot_volume_size_in_gbs = 50
  }

  lifecycle {
    # rekey delivers keys in-guest (systemctl restart agent-startup), never via
    # user_data — so changing the template or key must not try to rebuild.
    ignore_changes = [metadata, source_details]
  }
}
