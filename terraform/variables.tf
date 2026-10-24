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
  description = "Configuration for each VM, keyed by the VM name"
  type = map(object({
    id          = number
    name        = string
    description = string
    cpu_cores   = optional(number, 2)
    cpu_sockets = optional(number, 1)
    memory      = optional(number, 2048) # MiB
    disk_size   = optional(string, "10G")

    # false = Terraform only manages the VM itself (CPU, memory, disk, network). No Docker setup.
    provision = optional(bool, true)
  }))

  validation {
    condition     = alltrue([for k, v in var.vm_configs : k == v.name])
    error_message = "The key of each vm_configs entry must equal its name (docker/<name>/ is looked up by name). Mismatch in: ${join(", ", [for k, v in var.vm_configs : k if k != v.name])}"
  }

  validation {
    condition     = length(distinct([for v in values(var.vm_configs) : v.id])) == length(var.vm_configs)
    error_message = "Every vm_configs entry needs a unique id. Repeated id(s): ${join(", ", distinct([for v in values(var.vm_configs) : tostring(v.id) if length([for w in values(var.vm_configs) : w.id if w.id == v.id]) > 1]))}"
  }

  validation {
    condition     = alltrue([for v in values(var.vm_configs) : v.id >= 100 && v.id <= 999999999])
    error_message = "A Proxmox VM id must be between 100 and 999999999. Invalid in: ${join(", ", [for k, v in var.vm_configs : k if v.id < 100 || v.id > 999999999])}"
  }

  validation {
    condition     = alltrue([for v in values(var.vm_configs) : v.memory >= 512])
    error_message = "memory is in MiB and must be at least 512. Too small in: ${join(", ", [for k, v in var.vm_configs : k if v.memory < 512])}"
  }

  validation {
    condition     = alltrue([for v in values(var.vm_configs) : v.cpu_cores >= 1 && v.cpu_sockets >= 1])
    error_message = "cpu_cores and cpu_sockets must be at least 1. Invalid in: ${join(", ", [for k, v in var.vm_configs : k if v.cpu_cores < 1 || v.cpu_sockets < 1])}"
  }

  validation {
    condition     = alltrue([for v in values(var.vm_configs) : can(regex("^[0-9]+[MGT]$", v.disk_size))])
    error_message = "disk_size must be a number followed by M, G or T, for example \"40G\". Invalid in: ${join(", ", [for k, v in var.vm_configs : k if !can(regex("^[0-9]+[MGT]$", v.disk_size))])}"
  }
}
