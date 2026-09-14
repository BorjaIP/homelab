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
if [ -d "${MOUNT_POINT}/Backups/${1}/config" ] && [ -z "$(ls -A "${CONFIG_PATH}")" ]; then
    for entry in "${MOUNT_POINT}/Backups/${1}/config"/*; do
        name=$(basename "${entry}")
        echo "  - ${name}"
        rsync -a "${entry}" "${CONFIG_PATH}/"
    done
fi

case "$1" in
    gaghiel)
        echo "Step 4.5: Copying traefik configuration"
        mkdir -p "${CONFIG_PATH}/traefik"
        rsync -a --remove-source-files --delete "/home/${USER}/config.yaml" "${CONFIG_PATH}/traefik/config.yaml"
        rsync -a --remove-source-files --delete "/home/${USER}/routers" "${CONFIG_PATH}/traefik/"
        ;;
    matarael)
        echo "Step 4.5: Copying homepage configuration"
        mkdir -p "${CONFIG_PATH}/homepage"
        if [ -f "/home/${USER}/.env" ]; then
            export $(grep -v '^#' "/home/${USER}/.env" | grep -E '^(PROXMOX_USER|PROXMOX_PASS)=' | xargs)
        fi
        envsubst < "/home/${USER}/services-tpl.yaml" > "/home/${USER}/services.yaml" && rm "/home/${USER}/services-tpl.yaml"
        rsync -a --remove-source-files --delete "/home/${USER}/services.yaml" "${CONFIG_PATH}/homepage/services.yaml"
        rsync -a --remove-source-files --delete "/home/${USER}/widgets.yaml" "${CONFIG_PATH}/homepage/widgets.yaml"
        rsync -a --remove-source-files --delete "/home/${USER}/settings.yaml" "${CONFIG_PATH}/homepage/settings.yaml"
        ;;
    tabris)
        echo "Step 4.5: Copying nextcloud configuration"
        mkdir -p "${CONFIG_PATH}/nextcloud"
        sudo chown -R "33:33" "${CONFIG_PATH}/nextcloud"
        mkdir -p "${CONFIG_PATH}/before-starting"
        rsync -a --remove-source-files --delete "/home/${USER}/config.sh" "${CONFIG_PATH}/before-starting/config.sh"
        sudo chmod +x "${CONFIG_PATH}/before-starting/config.sh"
        ;;
esac

echo "Step 5: Adding user to the Docker group"
sudo usermod -aG docker "${USER}"

echo "Step 6: Deploying Docker Compose services"
sudo docker compose -f "/home/${USER}/docker-compose.yaml" up -d

echo "Step 7: Scheduling weekly backups"
CRON_JOB="0 3 * * 0 /home/${USER}/backup.sh >> /home/${USER}/backup.log 2>&1"
(crontab -l 2>/dev/null | grep -v "backup.sh" || true; echo "${CRON_JOB}") | crontab -

echo "All steps completed successfully!"