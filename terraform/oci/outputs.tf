output "instance_id" {
  description = "OCID of the agent instance"
  value       = oci_core_instance.agent.id
}

output "private_ip" {
  description = "Private IPv4 of the agent VNIC"
  value       = oci_core_instance.agent.private_ip
}

output "public_ip" {
  description = "Ephemeral public IPv4 of the agent VNIC (staging fallback)"
  value       = oci_core_instance.agent.public_ip
}

output "availability_domain" {
  description = "Availability domain the instance was placed in"
  value       = oci_core_instance.agent.availability_domain
}
