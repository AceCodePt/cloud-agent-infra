output "instance_ip" {
  value       = google_compute_instance.agent.network_interface[0].access_config[0].nat_ip
  description = "Ephemeral public IP. Nothing inbound uses it (it exists so Tailscale can dial out), and it changes on stop/start."
}

output "termux_host" {
  value = var.termux_host
}

output "termux_ssh_user" {
  value = var.termux_ssh_user
}

output "termux_ssh_port" {
  value = var.termux_ssh_port
}
