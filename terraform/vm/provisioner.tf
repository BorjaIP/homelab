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
    docker_file_hash = filesha256("${path.root}/docker/${var.name}/docker-compose.yaml")
    env_file_hash    = filesha256("${path.root}/.env")
    setup_file_hash  = filesha256("${path.root}/scripts/setup.sh")
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

  # Executing the setup script
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x /home/bis/setup.sh",
      "/home/bis/setup.sh ${var.name}"
    ]
  }
}
