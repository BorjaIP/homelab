terraform {
  required_version = ">= 1.3.0"

  required_providers {
    proxmox = {
      source  = "Telmate/proxmox" # original version
      version = "3.0.1-rc8"
    }
  }
}
