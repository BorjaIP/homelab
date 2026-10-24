locals {
  docker_dir = "${path.root}/docker/${var.name}"
  docker_dir_hash = sha256(join("", [
    for f in sort(fileset(local.docker_dir, "**")) : filesha256("${local.docker_dir}/${f}")
  ]))
}

resource "terraform_data" "docker_compose_setup" {
  # VMs with provision = false (installed by hand, like lilith) only get the VM, no Docker setup
  count = var.provision ? 1 : 0

  depends_on = [proxmox_vm_qemu.vm]

  connection {
    type        = "ssh"
    user        = "bis"
    private_key = file(var.private_ssh_key_file)
    host        = "192.168.1.${var.id}"
    agent       = false
    timeout     = "3m"
  }

  triggers_replace = {
    vm_uuid    = proxmox_vm_qemu.vm.smbios[0].uuid
    docker_dir = local.docker_dir_hash
    env        = filesha256("${path.root}/.env")
    setup      = filesha256("${path.root}/scripts/setup.sh")
    backup     = filesha256("${path.root}/scripts/backup.sh")
  }

  # Copying files
  provisioner "file" {
    source      = "${path.root}/docker/${var.name}/"
    destination = "/home/bis/"
  }

  provisioner "file" {
    source      = "${path.root}/.env"
    destination = "/home/bis/.env"
  }

  # Copying the setup script
  provisioner "file" {
    source      = "${path.root}/scripts/setup.sh"
    destination = "/home/bis/setup.sh"
  }
  provisioner "file" {
    source      = "${path.root}/scripts/backup.sh"
    destination = "/home/bis/backup.sh"
  }

  # Executing the setup script
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x /home/bis/backup.sh",
      "sudo chmod +x /home/bis/setup.sh",
      "/home/bis/setup.sh ${var.name}"
    ]
  }
}

# Keeps the existing state: the old null_resource becomes this one instead of being recreated
moved {
  from = null_resource.docker_compose_setup
  to   = terraform_data.docker_compose_setup
}

# The resource now has count, so its address gets an index; same object, no recreation
moved {
  from = terraform_data.docker_compose_setup
  to   = terraform_data.docker_compose_setup[0]
}
