# outputs.tf

output "instance_ip" {
  value       = google_compute_instance.agent.network_interface[0].access_config[0].nat_ip
  description = "Ephemeral public IP. Nothing inbound uses it (it exists so Tailscale can dial out), and it changes on stop/start."
}

# Consumed by scripts/provision-phone.sh and scripts/verify.sh. config.env only
# needs to set the values it overrides, so the scripts must be able to read the
# effective value (variable default included) rather than re-hardcoding it and
# drifting.
output "termux_host" {
  value = var.termux_host
}

output "termux_ssh_user" {
  value = var.termux_ssh_user
}

output "termux_ssh_port" {
  value = var.termux_ssh_port
}
