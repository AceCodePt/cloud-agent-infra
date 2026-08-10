variable "tenancy_ocid" {
  type        = string
  sensitive   = true
  description = "OCI tenancy OCID. From config.env: OCI_TENANCY_OCID."
}

variable "user_ocid" {
  type        = string
  sensitive   = true
  description = "OCI API user OCID. From config.env: OCI_USER_OCID."
}

variable "fingerprint" {
  type        = string
  sensitive   = true
  description = "OCI API key fingerprint. From config.env: OCI_FINGERPRINT."
}

variable "private_key_path" {
  type        = string
  description = "Path to the OCI API private key PEM. From config.env: OCI_PRIVATE_KEY_PATH."
}

variable "region" {
  type        = string
  default     = "il-jerusalem-1"
  description = "OCI region (home region hosts the Always Free capacity)."
}

variable "compartment_id" {
  type        = string
  default     = ""
  description = "OCI compartment OCID. Empty = root compartment (tenancy OCID)."
}

variable "instance_name" {
  type        = string
  default     = "cloud-agent"
  description = "Instance name and tailnet hostname"
}

variable "machine_type" {
  type        = string
  default     = "VM.Standard.A1.Flex"
  description = "ARM Ampere A1 Flex shape (Always Free eligible)"
}

variable "ocpus" {
  type        = number
  default     = 2
  description = "OCPUs for the A1 Flex shape (Always Free: up to 4)"
}

variable "memory_in_gbs" {
  type        = number
  default     = 12
  description = "RAM for the A1 Flex shape (Always Free: up to 24 GB)"
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
  default     = 50
  description = "Block volume for repos + tailscale state + browser profiles (OCI minimum is 50 GB)"
}

variable "data_label" {
  type        = string
  default     = "cloud-agent-data"
  description = "Filesystem LABEL given to the data volume; startup discovers it by label"
}

variable "custom_image_id" {
  description = "OCID of a pre-built OCI custom image (e.g. our Arch Linux ARM64 image). Empty => boot stock Oracle Linux and run startup.arch.sh."
  type        = string
  default     = ""
}
