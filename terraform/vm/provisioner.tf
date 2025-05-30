resource "null_resource" "docker_compose_setup" {
  depends_on = [proxmox_vm_qemu.vm]

  connection {
    type        = "ssh"
    user        = "bis"
    private_key = file(var.private_ssh_key_file)
    host        = "192.168.1.${var.id}"
    agent       = false
    timeout     = "3m"
  }

  triggers = {
    always_run = timestamp()
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
