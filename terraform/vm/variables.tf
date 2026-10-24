# Proxmox
variable "proxmox_host" {
  type     = string
  nullable = false
}

variable "template_name" {
  type     = string
  nullable = false
}

# VM
variable "name" {
  type     = string
  nullable = false
}

variable "description" {
  type = string
}

variable "id" {
  type     = number
  nullable = false
}

variable "cpu_cores" {
  type     = number
  nullable = false
}

variable "cpu_sockets" {
  type     = number
  nullable = false
}

variable "memory" {
  type     = number
  nullable = false
}

variable "disk_size" {
  type     = string
  nullable = false
}

variable "provision" {
  type     = bool
  nullable = false
}

variable "public_ssh_key" {
  type      = string
  sensitive = true
  default   = null
}

variable "private_ssh_key_file" {
  type      = string
  sensitive = true
  default   = null
}
