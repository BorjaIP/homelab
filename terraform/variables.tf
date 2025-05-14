# Proxmox
variable "proxmox_api_url" {
  type        = string
  description = "Url is the hostname (FQDN if you have one) for the proxmox host you'd like to connect to to issue the commands."
  default     = "https://prox-1u:8006/api2/json"
}

variable "proxmox_token_id" {
  type        = string
  description = "<username>@pam!<tokenId>"
  default     = null
}

variable "proxmox_token_secret" {
  type        = string
  sensitive   = true
  description = "This is the full secret wrapped in quotes"
  default     = null
}

variable "proxmox_host" {
  type        = string
  description = "The hostname of the proxmox server"
  default     = null
}

variable "template_name" {
  type        = string
  description = "The name of the template to use for creating VMs"
  default     = null
}

variable "public_ssh_key" {
  type        = string
  description = "The public SSH key to use for connecting to the VMs"
  sensitive   = true
  default     = null
}

variable "private_ssh_key_file" {
  type        = string
  description = "The path to the private SSH key file"
  sensitive   = true
  default     = null
}

variable "vm_configs" {
  description = "Configuration for each VM"
  type = map(object({
    id          = number
    name        = string
    description = string
    cpu_cores   = number
    cpu_sockets = number
    memory      = number
    disk_size   = string
  }))
}
