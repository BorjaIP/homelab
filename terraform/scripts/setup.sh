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

case "$1" in
    gaghiel)
        echo "Step 4.5: Copying traefik configuration"
        mkdir -p "${CONFIG_PATH}/traefik"
        rsync -a --info=progress2 --remove-source-files "/home/${USER}/config.yaml" "${CONFIG_PATH}/traefik/config.yaml"
        rsync -a --info=progress2 --remove-source-files "/home/${USER}/routers" "${CONFIG_PATH}/traefik/"
        ;;
    matarael)
        echo "Step 4.5: Copying homepage configuration"
        mkdir -p "${CONFIG_PATH}/homepage"
        if [ -f "/home/${USER}/.env" ]; then
            export $(grep -v '^#' "/home/${USER}/.env" | grep -E '^(PROXMOX_USER|PROXMOX_PASS)=' | xargs)
        fi
        envsubst < "/home/${USER}/services-tpl.yaml" > "/home/${USER}/services.yaml" && rm "/home/${USER}/services-tpl.yaml"
        rsync -a --info=progress2 --remove-source-files --delete "/home/${USER}/services.yaml" "${CONFIG_PATH}/homepage/services.yaml"
        ;;
    tabris)
        echo "Step 4.5: Copying nextcloud configuration"
        mkdir -p "${CONFIG_PATH}/nextcloud"
        sudo chown -R "33:33" "${CONFIG_PATH}/nextcloud"
        mkdir -p "${CONFIG_PATH}/before-starting"
        rsync -a --info=progress2 --remove-source-files --delete "/home/${USER}/config.sh" "${CONFIG_PATH}/before-starting/config.sh"
        sudo chmod +x "${CONFIG_PATH}/before-starting/config.sh"
        ;;
esac

echo "Step 5: Adding user to the Docker group"
sudo usermod -aG docker "${USER}"

echo "Step 6: Deploying Docker Compose services"
sudo docker compose -f "/home/${USER}/docker-compose.yaml" up -d

echo "All steps completed successfully!"