#!/bin/bash
# Backs up what Packer/Terraform cannot rebuild: the hand-made VMs (israfel, leliel, lilith) and
# the Proxmox host configuration. Run as root ON the Proxmox host.
#
# Output goes next to the other VMs' config backups, one folder per machine name:
#   <NFS mount>/Backups/israfel/vzdump/        vzdump-qemu-207-*.vma.zst  (storage bk-israfel)
#   <NFS mount>/Backups/leliel/vzdump/         vzdump-qemu-212-*.vma.zst  (storage bk-leliel)
#   <NFS mount>/Backups/lilith/vzdump/         vzdump-qemu-202-*.vma.zst  (storage bk-lilith)
#   <NFS mount>/Backups/proxmox/               pve-host_<host name>_<timestamp>.tar.gz
#
# Usage: proxmox-backup.sh [all|vms|host]    (default: all)
set -euo pipefail

# Where Proxmox mounts the NFS storage (/mnt/pve/<storage id>). It must be the same export as
# /mnt/storage on the VMs, so that Backups/ here is the Backups/ the other VMs write to.
NFS_MOUNT="${NFS_MOUNT:-/mnt/pve/nfs-storage}"
BACKUP_ROOT="${NFS_MOUNT}/Backups"

# VM IDs installed by hand: 207 = israfel (NFS server), 212 = leliel (HAOS), 202 = lilith
# (Hermes assistant; Terraform only creates the VM, provision = false).
MANUAL_VMS=(207 212 202)

# How many backups to keep per machine. VMs: Proxmox prunes the storage after a successful
# backup. Host: pruned by this script, also only after the new archive was written.
KEEP_VZDUMP=3
KEEP_HOST=8

TMP_DIR=""

log() { echo "[$(date +%H:%M:%S)] $*"; }

check_prereqs() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Run as root on the Proxmox host." >&2
        exit 1
    fi
    if ! command -v vzdump >/dev/null 2>&1; then
        echo "vzdump not found: this does not look like a Proxmox host." >&2
        exit 1
    fi
    # Never create the backup tree on the local disk by accident if the NFS is not mounted.
    if ! mountpoint -q "${NFS_MOUNT}"; then
        echo "${NFS_MOUNT} is not mounted. Check 'pvesm status' (israfel must be running)." >&2
        exit 1
    fi
    if [ ! -d "${BACKUP_ROOT}" ]; then
        echo "${BACKUP_ROOT} does not exist: wrong NFS export? It must map to /mnt/storage/Backups." >&2
        exit 1
    fi
}

# prune <dir> <glob> <keep>: delete everything but the newest <keep> files matching <glob>.
prune() {
    local dir="$1" pattern="$2" keep="$3" f
    while IFS= read -r f; do
        log "  pruning ${f}"
        rm -f -- "${f}"
    done < <(find "${dir}" -maxdepth 1 -type f -name "${pattern}" | sort -r | tail -n +$((keep + 1)))
}

backup_vm() {
    local id="$1" name storage
    name="$(qm config "${id}" | awk '/^name:/ {print $2}')"
    if [ -z "${name}" ]; then
        echo "VM ${id} not found on this node." >&2
        return 1
    fi
    # One Proxmox "Directory" storage per machine (created once, see docs/proxmox-backups.md),
    # so the backups show up in the GUI and live in Backups/<name>/vzdump/.
    storage="bk-${name}"
    if ! pvesm status --storage "${storage}" >/dev/null 2>&1; then
        echo "Storage ${storage} is missing or offline. Create it first (docs/proxmox-backups.md)." >&2
        return 1
    fi
    log "VM ${id} (${name}) -> storage ${storage}"
    vzdump "${id}" --storage "${storage}" --mode snapshot --compress zstd \
        --prune-backups "keep-last=${KEEP_VZDUMP}"
}

backup_host() {
    local name ts dest out path
    local -a paths=()
    name="$(hostname)"
    ts="$(date +%Y%m%d%H%M%S)"
    dest="${BACKUP_ROOT}/proxmox"
    out="${dest}/pve-host_${name}_${ts}.tar.gz"
    mkdir -p "${dest}"
    log "Host ${name} -> ${out}"

    # Runtime state that is not in any file but helps to rebuild the host by hand.
    TMP_DIR="$(mktemp -d)"
    mkdir -p "${TMP_DIR}/info"
    pveversion -v >"${TMP_DIR}/info/pveversion.txt"
    pvesm status >"${TMP_DIR}/info/pvesm-status.txt"
    qm list >"${TMP_DIR}/info/qm-list.txt"
    pct list >"${TMP_DIR}/info/pct-list.txt"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL >"${TMP_DIR}/info/lsblk.txt"
    blkid >"${TMP_DIR}/info/blkid.txt" || true
    ip -br addr >"${TMP_DIR}/info/ip-addr.txt"

    # Package state, to see what the upgrade changed and to reinstall by hand if needed.
    dpkg --get-selections >"${TMP_DIR}/info/dpkg-selections.txt"
    apt-mark showmanual >"${TMP_DIR}/info/apt-manual.txt"

    # The whole /etc (a Proxmox upgrade rewrites conffiles all over it). It includes /etc/pve:
    # storage.cfg, user.cfg, jobs.cfg, every VM .conf and the cluster secrets (priv/).
    # Plus root's cron jobs.
    for path in etc var/spool/cron; do
        [ -e "/${path}" ] && paths+=("${path}")
    done

    tar czf "${out}" -C / "${paths[@]}" -C "${TMP_DIR}" info
    chmod 600 "${out}"
    prune "${dest}" "pve-host_${name}_*.tar.gz" "${KEEP_HOST}"
}

main() {
    local target="${1:-all}" id
    if [[ ! "${target}" =~ ^(all|vms|host)$ ]]; then
        echo "Usage: $0 [all|vms|host]" >&2
        exit 1
    fi
    check_prereqs
    trap 'rm -rf "${TMP_DIR}"' EXIT

    if [[ "${target}" == all || "${target}" == vms ]]; then
        for id in "${MANUAL_VMS[@]}"; do
            backup_vm "${id}"
        done
    fi
    if [[ "${target}" == all || "${target}" == host ]]; then
        backup_host
    fi
    log "Done."
}

main "$@"
