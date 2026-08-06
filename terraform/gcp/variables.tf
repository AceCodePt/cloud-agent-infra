variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type    = string
  default = "me-west1"
}

variable "zone" {
  type    = string
  default = "me-west1-a"
}

variable "machine_type" {
  type        = string
  default     = "e2-standard-2"
  description = "2 full vCPU / 8GB. e2-medium for a leaner setup."
}

variable "instance_name" {
  type        = string
  default     = "cloud-agent"
  description = "VM name and tailnet hostname"
}

variable "data_disk_size_gb" {
  type        = number
  default     = 20
  description = "Persistent disk for repos + tailscale state"
}

variable "ssh_user" {
  type        = string
  description = "Your Unix user on the box (also the tailnet SSH user)"
}

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "Optional. Your public key, authorized on the box for sshd. Only needed to use YOUR key through a raw IAP tunnel (e.g. editor Remote-SSH without Tailscale) — `gcloud compute ssh` injects its own ephemeral key, and Tailscale SSH needs no key at all."
}

variable "tailscale_auth_key" {
  type        = string
  sensitive   = true
  description = "Tailscale auth key used once, on first boot, to join the tailnet. Normally you do NOT set this by hand: with TAILSCALE_API_KEY in config.env, bootstrap.sh mints a fresh single-use, pre-approved key per build and writes it to tailscale.auto.tfvars (git-ignored), which Terraform auto-loads. Set it manually only if you'd rather manage a reusable key from the admin console."
}
