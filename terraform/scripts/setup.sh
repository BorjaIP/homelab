#!/bin/bash
set -e

USER="bis"
CONFIG_PATH="/home/${USER}/config"
MOUNT_POINT="/mnt/storage"
NFS_SERVER_IP="192.168.1.207"

echo "Step 1: Installing NFS client"
if ! dpkg -s nfs-common >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y nfs-common
fi

echo "Step 2: Creating NFS mount point"
sudo mkdir -p "${MOUNT_POINT}"

echo "Step 3: Configuring NFS mount in /etc/fstab"
if ! grep -q "${NFS_SERVER_IP}:${MOUNT_POINT} ${MOUNT_POINT} nfs defaults 0 0" /etc/fstab; then
    echo "${NFS_SERVER_IP}:${MOUNT_POINT} ${MOUNT_POINT} nfs defaults 0 0" | sudo tee -a /etc/fstab
    sudo mount -a
    sudo systemctl daemon-reload
fi

echo "Step 4: Recovering backup"
mkdir -p "${CONFIG_PATH}"
if [ -d "${MOUNT_POINT}/backups/${1}/config" ] && [ ! -f "${CONFIG_PATH}/.rsync_done" ]; then
    rsync -a --info=progress2 "${MOUNT_POINT}/backups/${1}/config" "${CONFIG_PATH}/"
    touch "${CONFIG_PATH}/.rsync_done"
fi

# echo "Step 5: Configuring Docker to expose TCP on port 2375"
# if ! grep -q 'tcp://0.0.0.0:2375' /lib/systemd/system/docker.service; then
#     sudo sed -i 's|ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock|ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock -H tcp://0.0.0.0:2375|' /lib/systemd/system/docker.service
#     sudo systemctl daemon-reload
#     sudo systemctl restart docker
# fi

echo "Step 5: Adding user to the Docker group"
sudo usermod -aG docker "${USER}"

echo "Step 6: Deploying Docker Compose services"
sudo docker compose -f "/home/${USER}/docker-compose.yaml" up -d

echo "All steps completed successfully!"