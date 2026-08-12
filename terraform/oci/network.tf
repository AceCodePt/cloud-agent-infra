locals {
  compartment = var.compartment_id != "" ? var.compartment_id : var.tenancy_ocid
}

# VCN in a private CIDR. OCI requires explicit networking (unlike Hetzner).
# is_ipv6enabled: Oracle allocates a /56 GUA prefix, so Tailscale can take a
# direct (non-DERP) path to the box from any IPv6-capable network. Once set, it
# cannot be disabled.
resource "oci_core_vcn" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "agentvcn"
  is_ipv6enabled = true
}

# Internet gateway: the ONLY gateway. The instance has a public IPv4 + a public
# IPv6, and both families egress through the same IGW. A NAT gateway cannot be
# used here: return traffic to a public-IP VNIC would go out the NAT gateway
# (IPv4-only, outbound-only), which would break every inbound IPv4 connection.
resource "oci_core_internet_gateway" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-igw"
  vcn_id         = oci_core_vcn.agent.id
}

resource "oci_core_route_table" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-rt"
  vcn_id         = oci_core_vcn.agent.id

  # IPv4 egress via the IGW. Outbound sources the VNIC's public IPv4; the
  # security list gates inbound (only Tailscale WireGuard, UDP 41641).
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.agent.id
  }

  # IPv6 egress via the internet gateway (inbound + outbound).
  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.agent.id
  }
}

resource "oci_core_subnet" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-subnet"
  vcn_id         = oci_core_vcn.agent.id
  cidr_block     = "10.0.0.0/24"

  # IPv6: carve the first /64 out of the VCN's Oracle-allocated /56 GUA prefix.
  ipv6cidr_block = cidrsubnet(oci_core_vcn.agent.ipv6cidr_blocks[0], 8, 0)

  # Public subnet: the VNIC gets a reserved public IPv4 (oci_core_public_ip in
  # compute.tf) for the direct Tailscale endpoint, plus a public IPv6.
  # Reachability beyond WireGuard is blocked by the security list. DNS must be
  # enabled for the instance hostname_label.
  route_table_id    = oci_core_route_table.agent.id
  security_list_ids = [oci_core_security_list.agent.id]
  dns_label         = "agentsub"
}

# Security posture: the ONLY public ingress on BOTH families is Tailscale's
# WireGuard port — IPv4 UDP 41641 from 0.0.0.0/0 and IPv6 UDP 41641 from ::/0.
# The box has a reserved public IPv4 + a public IPv6 as direct endpoints, so
# both rules are live. WireGuard does not respond to unauthenticated
# handshakes, so nothing else is exposed. SSH remains key-only and reachable
# only over the tailnet.
resource "oci_core_security_list" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-sl"
  vcn_id         = oci_core_vcn.agent.id

  # IPv4 ingress: Tailscale/WireGuard direct path.
  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "17" # UDP
    description = "Tailscale WireGuard (UDP 41641) — direct IPv4 path"
    udp_options {
      min = 41641
      max = 41641
    }
  }

  # IPv6 ingress: Tailscale/WireGuard direct path only.
  ingress_security_rules {
    source      = "::/0"
    source_type = "CIDR_BLOCK"
    protocol    = "17" # UDP
    description = "Tailscale WireGuard (UDP 41641) — direct IPv6 path"
    udp_options {
      min = 41641
      max = 41641
    }
  }

  # IPv4 egress: unchanged, all outbound.
  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  # IPv6 egress: all outbound (needed for DHCPv6 + any v6 egress).
  egress_security_rules {
    destination      = "::/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }
}
