variable "vultr_api_key" {
  type        = string
  sensitive   = true
  description = "Vultr personal access token (read & write). From config.env: VULTR_API_KEY."
}

variable "instance_name" {
  type        = string
  default     = "cloud-agent"
  description = "Instance label and tailnet hostname"
}

variable "machine_type" {
  type        = string
  default     = "vhp-4c-8gb-amd"
  description = "Vultr plan ID. vhp-4c-8gb-amd = 4 vCPU / 8 GB / 180 GB, $48/mo in tlv."
}

variable "region" {
  type        = string
  default     = "tlv"
  description = "Vultr region. tlv = Tel Aviv (in-country)."
}

variable "os_id" {
  type        = number
  default     = 1869
  description = "Vultr OS id. 1869 = Rocky Linux 9 x64 (matches startup.rhel.sh)."
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
  default     = 40
  description = "Volume for repos + tailscale state + browser profiles (tlv storage_opt floor is 40)"
}

variable "data_label" {
  type        = string
  default     = "cloud-agent-data"
  description = "Filesystem LABEL given to the data volume; startup discovers it by label"
}
