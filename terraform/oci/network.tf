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

# NAT gateway for OUTBOUND-only internet: the instance has NO public IP, so
# nothing can even attempt inbound from the internet. Tailscale dials out
# through the NAT gateway; the phone's exit node is reached over the tailnet.
resource "oci_core_nat_gateway" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-ngw"
  vcn_id         = oci_core_vcn.agent.id
}

# Internet gateway for IPv6 only. IPv6 GUA is only internet-routable from a
# PUBLIC subnet via an internet gateway (NAT gateways are IPv4-only), so the
# subnet needs ::/0 -> IGW for the Tailscale direct path. IPv4 stays private
# behind the NAT gateway; the instance keeps no public IPv4.
resource "oci_core_internet_gateway" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-igw"
  vcn_id         = oci_core_vcn.agent.id
}

resource "oci_core_route_table" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-rt"
  vcn_id         = oci_core_vcn.agent.id

  # IPv4 egress via NAT (private, outbound-only — as before).
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.agent.id
  }

  # IPv6 egress via the internet gateway (inbound + outbound). This is what
  # makes the subnet effectively "public" for IPv6 traffic.
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

  # Private subnet: no public IP on the VNIC. Reachability is Tailscale-only,
  # established outbound. DNS must be enabled for the instance hostname_label.
  route_table_id    = oci_core_route_table.agent.id
  security_list_ids = [oci_core_security_list.agent.id]
  dns_label         = "agentsub"
}

# Security posture: IPv4 has NO public ingress at all; IPv6 opens exactly ONE
# port — UDP 41641, Tailscale's WireGuard listener — so the box can take a
# direct (non-DERP) Tailscale path from IPv6-capable networks. WireGuard does
# not respond to unauthenticated handshakes, so nothing else is exposed.
# IPv4 public ingress stays empty (the exact equivalent of the old empty rule
# set); SSH remains key-only and reachable only over the tailnet.
resource "oci_core_security_list" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-sl"
  vcn_id         = oci_core_vcn.agent.id

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
