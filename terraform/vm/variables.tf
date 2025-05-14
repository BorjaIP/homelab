# Proxmox
variable "proxmox_host" {
  type    = string
  default = null
}

variable "template_name" {
  type    = string
  default = null
}

# VM
variable "name" {
  type    = string
  default = null
}

variable "description" {
  type    = string
  default = null
}

variable "id" {
  type    = number
  default = 100
}

variable "cpu_cores" {
  type    = number
  default = 2
}

variable "cpu_sockets" {
  type    = number
  default = 1
}

variable "memory" {
  type    = number
  default = 2048
}

variable "disk_size" {
  type    = string
  default = "10G"
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
