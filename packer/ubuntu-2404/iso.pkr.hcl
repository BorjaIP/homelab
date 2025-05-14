# https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox
source "proxmox-iso" "ubuntu-server-2404" {
  proxmox_url = "${var.proxmox_api_url}"
  username    = "${var.proxmox_api_token_id}"
  token       = "${var.proxmox_api_token_secret}"

  # (Optional) Skip TLS Verification
  insecure_skip_tls_verify = true

  # VM General Settings
  node                 = "${var.proxmox_node}"
  vm_id                = "900"
  vm_name              = "ubuntu-server-24.04"
  template_name        = "ubuntu-server-24.04"
  template_description = "Ubuntu 24.04 LTS"

  # VM OS Settings
  boot_iso {
    iso_file         = "local:iso/ubuntu-24.04.2-live-server-amd64.iso"
    iso_storage_pool = "local"
    unmount          = true
  }

  qemu_agent = true

  # VM CPU/RAM Settings
  cores   = "1"
  sockets = "1"
  memory  = "2048"

  # VM Hard Disk Settings
  scsi_controller = "virtio-scsi-pci"

  disks {
    disk_size    = "10G"
    format       = "raw"
    storage_pool = "local-lvm"
    type         = "virtio"
  }

  # VM Network Settings
  network_adapters {
    model    = "virtio"
    bridge   = "vmbr0"
    firewall = "false"
  }

  # VM Cloud-Init Settings
  cloud_init              = true
  cloud_init_storage_pool = "local-lvm"

  # Boot Commands
  boot_command = [
    "<esc><wait>",
    "e<wait>",
    "<down><down><down><end>",
    "<bs><bs><bs><bs><wait>",
    "autoinstall ip=${cidrhost("192.168.1.0/24", 125)}::${cidrhost("192.168.1.0/24", 1)}:${cidrnetmask("192.168.1.0/24")}::::${cidrhost("192.168.1.0/24", 1)} net.ifnames=0 biosdevname=0 ipv6.disable=1 ds='nocloud-net;s=http://${var.http_server_host}:${var.http_server_port}/' ---",
    "<wait><f10><wait>"
  ]
  boot      = "c"
  boot_wait = "5s"

  # Autoinstall Settings
  http_directory = "http"
  http_port_min  = var.http_server_port
  http_port_max  = var.http_server_port

  # SSH Settings
  ssh_username              = var.ssh_username
  ssh_private_key_file      = var.ssh_private_key_file
  ssh_clear_authorized_keys = true

  # Raise the timeout, when installation takes longer
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 15
}