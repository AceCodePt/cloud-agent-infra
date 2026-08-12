locals {
  # The instance boots OCI's stock Oracle Linux 9 platform image and provisions
  # itself at first boot via startup.rhel.sh (rendered into user_data) — the
  # single RHEL-family template shared by every provider (OCI boots Oracle
  # Linux, others boot Rocky Linux 9; the setup process after image selection
  # is identical). Provisioning must happen on the box, never baked into an
  # image, so user_data is never empty. startup.rhel.sh installs Flatpak
  # Chromium (not snap), the GitHub-release build of neovim/direnv/mise, and
  # the rest of the stack in a deferred phase B.
  source_id = data.oci_core_images.oracle_linux.images[0].id
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

  # OCI paravirtualized block volumes attach as /dev/oracleoci/oraclevdb (an
  # /dev/sdb alias also appears). startup.rhel.sh waits for it before deciding
  # the data disk is missing.
  data_dev = "/dev/oracleoci/oraclevdb"
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = local.compartment
}

# Oracle Linux 9, aarch64. Filter for the latest arm64 image; if none is
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
    # No EPHEMERAL public IP on the VNIC: the reserved public IPv4 comes from
    # oci_core_public_ip below, so a second (ephemeral) address would be
    # pointless. The subnet is public, so the reserved IP can attach.
    subnet_id        = oci_core_subnet.agent.id
    assign_public_ip = false
    hostname_label   = var.instance_name
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand("~/.ssh/id_ed25519.pub"))
    user_data           = base64encode(local.startup_script)
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

# The instance's primary VNIC, so we can attach a public IPv6 (Tailscale direct
# path). The VNIC is created implicitly by the instance resource, so it is
# looked up by attachment instead of declared directly.
data "oci_core_vnic_attachments" "agent" {
  compartment_id = local.compartment
  instance_id    = oci_core_instance.agent.id
}

resource "oci_core_ipv6" "agent" {
  # Oracle assigns the address from the subnet's IPv6 /64. "RESERVED" keeps the
  # address stable across a stop/start (an ephemeral one can change on reboot).
  vnic_id      = data.oci_core_vnic_attachments.agent.vnic_attachments[0].vnic_id
  subnet_id    = oci_core_subnet.agent.id
  lifetime     = "RESERVED"
  display_name = "${var.instance_name}-ipv6"
}

# Public IPv4 for a stable direct (non-DERP) Tailscale endpoint. "RESERVED"
# keeps it fixed across stop/start and rebuilds. The VNIC is in a public
# subnet (prohibit_public_ip_on_vnic = false), so the IP attaches to the
# existing primary private IP — no instance rebuild needed. This is what lets
# the box be reached directly even from symmetric-NAT (office) networks.
data "oci_core_private_ips" "agent" {
  vnic_id = data.oci_core_vnic_attachments.agent.vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-ipv4"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.agent.private_ips[0].id
}
