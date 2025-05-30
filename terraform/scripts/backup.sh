#!/bin/bash
set -e

USER="bis"
CONFIG_PATH="/home/${USER}/config"
MOUNT_POINT="/mnt/storage"
NFS_SERVER_IP="192.168.1.207"

## Backup 
# Interval between automatic backups -> 7 days
# Automatic backups older than the retention period will be cleaned up automatically -> 28 days

echo "Step 1: Ensuring NFS mount is available"
if ! mount | grep -q "${MOUNT_POINT}"; then
    echo "NFS mount is not available. Attempting to mount..."
    sudo mount -a
fi

if ! mount | grep -q "${MOUNT_POINT}"; then
    echo "Failed to mount NFS. Exiting."
    exit 1
fi

echo "Step 2: Preparing backup directory"
BACKUP_DIR="${MOUNT_POINT}/backups/$(hostname)/config"

echo "Step 3: Zipping the old backup directory"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
if [ -d "${BACKUP_DIR}" ]; then
    # Create a zip file of the existing backup
    zip -rq "config_${TIMESTAMP}.zip" "${BACKUP_DIR}"
    
    # Remove the original directory after zipping
    echo "Removing the old backup directory..."
    sudo rm -rf "${BACKUP_DIR}"/*

    # Copy the zip file to the backup directory
    echo "Moving the zip file to the backup directory..."
    HOST_DIR="${MOUNT_POINT}/backups/$(hostname)"
    mv "config_${TIMESTAMP}.zip" "${HOST_DIR}/"
fi

echo "Step 3.5: Creating new backup directory"
mkdir -p "${BACKUP_DIR}"

echo "Step 4: Backing up configuration files"
if [ -d "${CONFIG_PATH}" ]; then
    rsync -a --info=progress2 "${CONFIG_PATH}/" "${BACKUP_DIR}/"
    echo "Backup completed successfully!"
else
    echo "Configuration directory ${CONFIG_PATH} does not exist. Skipping backup."
fi

echo "Backup completed successfully!"