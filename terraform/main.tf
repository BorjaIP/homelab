module "vms" {
  source = "./vm"

  for_each = var.vm_configs

  proxmox_host         = var.proxmox_host
  template_name        = var.template_name
  public_ssh_key       = var.public_ssh_key
  private_ssh_key_file = var.private_ssh_key_file

  id          = each.value.id
  name        = each.value.name
  description = each.value.description
  cpu_cores   = each.value.cpu_cores
  cpu_sockets = each.value.cpu_sockets
  memory      = each.value.memory
  disk_size   = each.value.disk_size
}
