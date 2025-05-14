# Proxmox
variable "proxmox_api_url" {
  type    = string
  default = "https://prox-1u:8006/api2/json"
}

variable "proxmox_api_token_id" {
  type        = string
  description = "<username>@pam!<tokenId>"
  default     = null
}

variable "proxmox_api_token_secret" {
  type        = string
  sensitive   = true
  description = "This is the full secret wrapped in quotes"
  default     = null
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node to connect."
  default     = null
}

# SSH
variable "ssh_username" {
  type        = string
  description = "SSH username."
  default     = null
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to private key file for SSH authentication."
  default     = null
}

# HTTP
variable "http_server_host" {
  type        = string
  description = "Overrides packers {{ .HTTPIP }} setting in the boot commands. Useful when running packer in WSL2."
  default     = null
}

variable "http_server_port" {
  type        = number
  description = "The port to serve the http_directory on. Overrides packers {{ .HTTPPort }} setting in the boot commands. Useful when running packer in WSL2."
  default     = null
}
