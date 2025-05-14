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

  # # Creating NFS
  # provisioner "remote-exec" {
  #   inline = [
  #     "sudo apt install -y nfs-common",
  #     "sudo mkdir -p /mnt/storage",
  #     "if ! grep -q '192.168.1.207:/mnt/storage /mnt/storage nfs defaults 0 0' /etc/fstab; then echo '192.168.1.207:/mnt/storage /mnt/storage nfs defaults 0 0' | sudo tee -a /etc/fstab; sudo mount -a; sudo systemctl daemon-reload; fi",
  #   ]
  # }

  # # Recovering backup
  # provisioner "remote-exec" {
  #   inline = [
  #     "mkdir -p /home/bis/config",
  #     "if [ -d /mnt/storage/backups/${var.name}/config ] && [ ! -d /home/bis/config/.rsync_done ]; then rsync -a --info=progress2 /mnt/storage/backups/${var.name}/config /home/bis/; touch /home/bis/config/.rsync_done; fi",
  #   ]
  # }

  # # Export Docker on TCP for traefik
  # provisioner "remote-exec" {
  #   inline = [
  #     "if ! grep -q 'tcp://0.0.0.0:2375' /lib/systemd/system/docker.service; then sudo sed -i 's|ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock|ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock -H tcp://0.0.0.0:2375|' /lib/systemd/system/docker.service && sudo systemctl daemon-reload && sudo systemctl restart docker; fi",
  #   ]
  # }

  # # Deploying services
  # provisioner "remote-exec" {
  #   inline = [
  #     "sudo usermod -aG docker bis",
  #     "sudo docker compose -f /home/bis/docker-compose.yaml up -d"
  #   ]
  # }
}
