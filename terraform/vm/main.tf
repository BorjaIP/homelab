# https://registry.terraform.io/providers/Telmate/proxmox/latest/docs/resources/vm_qemu
resource "proxmox_vm_qemu" "vm" {
  name        = var.name
  desc        = var.description
  target_node = var.proxmox_host

  tags = "docker"

  # VM options
  vmid    = var.id
  bios    = "seabios" # default=ovmf
  clone   = var.template_name
  os_type = "cloud-init"

  # Boot process
  onboot = true # VM startup after the PVE node starts
  boot   = "order=virtio0"

  # VM CPU/RAM Settings
  agent    = 1 # Activate QEMU agent for this VM
  cores    = var.cpu_cores
  sockets  = var.cpu_sockets
  cpu_type = "host"
  memory   = var.memory

  scsihw = "virtio-scsi-pci"

  # Setup the disk
  disks {
    ide {
      ide3 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
    virtio {
      virtio0 {
        disk {
          size    = var.disk_size
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Lifecycle
  lifecycle {
    ignore_changes = [
      disk,
      vm_state,
      sshkeys
    ]
  }

  # Cloud init template
  ipconfig0    = "ip=192.168.1.${var.id}/24,gw=192.168.1.1"
  searchdomain = "192.168.1.200"
  nameserver   = "192.168.1.200"
  ciuser       = "bis"
  sshkeys      = <<-EOF
  ${var.public_ssh_key}
  EOF
}
