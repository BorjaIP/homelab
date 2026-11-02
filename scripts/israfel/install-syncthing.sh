#!/bin/bash
# Installs Syncthing natively on israfel (Ubuntu 24.04) from the official apt repository and runs it as a
# system service under its own user. Run it as root on israfel; deploy.sh copies it there and runs it.
# It changes nothing outside the packages, one user, one data folder and one systemd drop-in.
#
# Usage: install-syncthing.sh [--dry-run]
# Env:   SYNC_USER (default syncthing), SYNC_MOUNT (default /mnt/storage), SYNC_DATA (default /mnt/storage/PKM),
#        SYNC_MEMORY_MAX (default 512M)
#
# The GUI stays on 127.0.0.1:8384 (Syncthing's default). Reach it from the PC with an SSH tunnel.
set -euo pipefail

SYNC_USER="${SYNC_USER:-syncthing}"
SYNC_MOUNT="${SYNC_MOUNT:-/mnt/storage}"
SYNC_DATA="${SYNC_DATA:-/mnt/storage/PKM}"
SYNC_MEMORY_MAX="${SYNC_MEMORY_MAX:-512M}"
KEYRING=/etc/apt/keyrings/syncthing-archive-keyring.gpg
SOURCES=/etc/apt/sources.list.d/syncthing.list
PIN=/etc/apt/preferences.d/syncthing.pref
DROPIN_DIR="/etc/systemd/system/syncthing@${SYNC_USER}.service.d"
SERVICE="syncthing@${SYNC_USER}.service"

dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

die() { echo "install-syncthing: $*" >&2; exit 1; }
step() { echo "==> $*"; }

if [ $dry -eq 0 ]; then
  [ "$(id -u)" -eq 0 ] || die "run as root"
  # Never create the data folder on the root disk by mistake: it would be an empty copy, not the NTFS disk.
  mountpoint -q "$SYNC_MOUNT" || die "$SYNC_MOUNT is not mounted"
fi

step "apt repository (official, channel stable-v2)"
if [ $dry -eq 1 ]; then
  echo "would download https://syncthing.net/release-key.gpg to $KEYRING"
  echo "would write $SOURCES : deb [signed-by=$KEYRING] https://apt.syncthing.net/ syncthing stable-v2"
  echo "would write $PIN : pin origin apt.syncthing.net at priority 990"
  echo "would run: apt-get update; apt-get install -y syncthing"
else
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/key.gpg" https://syncthing.net/release-key.gpg
  [ -s "$tmp/key.gpg" ] || die "empty release key"
  install -d -m 755 /etc/apt/keyrings
  install -m 644 "$tmp/key.gpg" "$KEYRING"
  echo "deb [signed-by=$KEYRING] https://apt.syncthing.net/ syncthing stable-v2" > "$SOURCES"
  printf 'Package: *\nPin: origin apt.syncthing.net\nPin-Priority: 990\n' > "$PIN"
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q syncthing
fi

step "service user $SYNC_USER"
if [ $dry -eq 1 ]; then
  echo "would create system user $SYNC_USER (home /var/lib/$SYNC_USER, no login shell) if missing"
elif id -u "$SYNC_USER" >/dev/null 2>&1; then
  echo "user $SYNC_USER already exists"
else
  useradd --system --create-home --home-dir "/var/lib/$SYNC_USER" --shell /usr/sbin/nologin "$SYNC_USER"
fi

step "data folder $SYNC_DATA"
if [ $dry -eq 1 ]; then
  echo "would create $SYNC_DATA and check that $SYNC_USER can write in it"
else
  mkdir -p "$SYNC_DATA"
  # NTFS here is mounted by ntfs-3g (fuseblk, owner root, open permissions): do not chown, test writing instead.
  runuser -u "$SYNC_USER" -- test -w "$SYNC_DATA" || die "$SYNC_USER cannot write in $SYNC_DATA"
fi

step "systemd drop-in (wait for the disk, 1 core, memory cap $SYNC_MEMORY_MAX)"
if [ $dry -eq 1 ]; then
  echo "would write $DROPIN_DIR/override.conf with RequiresMountsFor=$SYNC_MOUNT, GOMAXPROCS=1, MemoryMax=$SYNC_MEMORY_MAX"
  echo "would run: systemctl daemon-reload; systemctl enable --now $SERVICE"
else
  install -d -m 755 "$DROPIN_DIR"
  cat > "$DROPIN_DIR/override.conf" <<EOF
[Unit]
RequiresMountsFor=$SYNC_MOUNT

[Service]
Environment=GOMAXPROCS=1
MemoryMax=$SYNC_MEMORY_MAX
EOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null http://127.0.0.1:8384/; then break; fi
    sleep 1
  done
  systemctl is-active "$SERVICE"
  curl -s -o /dev/null -w 'GUI http://127.0.0.1:8384 -> HTTP %{http_code}\n' http://127.0.0.1:8384/ || die "GUI does not answer"
fi

echo
echo "Done. The GUI listens only on 127.0.0.1:8384 of israfel. From the PC:"
echo "  ssh -L 8384:127.0.0.1:8384 israfel-nfs     # then open http://localhost:8384"
echo "Set a GUI user and password the first time you open it."
