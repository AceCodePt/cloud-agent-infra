variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token (read & write). From config.env: HETZNER_API_KEY."
}

variable "instance_name" {
  type        = string
  default     = "cloud-agent"
  description = "Server name and tailnet hostname"
}

variable "machine_type" {
  type        = string
  default     = "cx33"
  description = "4 vCPU / 8 GB shared. cx23 (2/4) for a leaner setup."
}

variable "location" {
  type        = string
  default     = "nbg1"
  description = "Hetzner datacenter: nbg1 (Nuremberg), fsn1 (Falkenstein), hel1 (Helsinki)"
}

variable "ssh_user" {
  type        = string
  description = "Your Unix user on the box (also the tailnet SSH user)"
}

variable "tailscale_auth_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "One-off Tailscale auth key, minted per build into tailscale.auto.tfvars"
}

variable "data_disk_size_gb" {
  type        = number
  default     = 20
  description = "Volume for repos + tailscale state + browser profiles"
}

variable "data_label" {
  type        = string
  default     = "cloud-agent-data"
  description = "Filesystem LABEL given to the data volume; startup discovers it by label"
}
