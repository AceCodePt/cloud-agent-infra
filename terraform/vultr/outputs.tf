output "instance_id" {
  value       = vultr_instance.agent.id
  description = "Vultr instance ID"
}

output "instance_label" {
  value       = vultr_instance.agent.label
  description = "Instance label (also the tailnet hostname)"
}

output "main_ip" {
  value       = vultr_instance.agent.main_ip
  description = "Public IPv4 address (direct Tailscale endpoint)"
}

output "firewall_group_id" {
  value       = vultr_firewall_group.agent.id
  description = "Firewall group id (inbound is exactly UDP 41641)"
}

output "data_volume_id" {
  value       = vultr_block_storage.agent.id
  description = "Block storage id backing /mnt/data"
}
