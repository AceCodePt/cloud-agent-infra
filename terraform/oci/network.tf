locals {
  compartment = var.compartment_id != "" ? var.compartment_id : var.tenancy_ocid
}

# VCN in a private CIDR. OCI requires explicit networking (unlike Hetzner).
resource "oci_core_vcn" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "agentvcn"
}

# NAT gateway for OUTBOUND-only internet: the instance has NO public IP, so
# nothing can even attempt inbound from the internet. Tailscale dials out
# through the NAT gateway; the phone's exit node is reached over the tailnet.
resource "oci_core_nat_gateway" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-ngw"
  vcn_id         = oci_core_vcn.agent.id
}

resource "oci_core_route_table" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-rt"
  vcn_id         = oci_core_vcn.agent.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.agent.id
  }
}

resource "oci_core_subnet" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-subnet"
  vcn_id         = oci_core_vcn.agent.id
  cidr_block     = "10.0.0.0/24"

  # Private subnet: no public IP on the VNIC. Reachability is Tailscale-only,
  # established outbound. DNS must be enabled for the instance hostname_label.
  route_table_id    = oci_core_route_table.agent.id
  security_list_ids = [oci_core_security_list.agent.id]
  dns_label         = "agentsub"
}

# Security posture: NO public ingress, all outbound permitted. An empty
# ingress rule set is the exact equivalent of the Hetzner firewall's empty rule
# set. Stateful replies are handled by OCI's default (stateful rules).
resource "oci_core_security_list" "agent" {
  compartment_id = local.compartment
  display_name   = "${var.instance_name}-sl"
  vcn_id         = oci_core_vcn.agent.id

  # No public ingress at all -> nothing can reach the box from outside the VCN.

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }
}
