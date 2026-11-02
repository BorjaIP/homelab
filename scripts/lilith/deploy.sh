#!/bin/bash
# Installs the pkm-sync script and its systemd user units from this repo onto the VM.
# Run it from the PC. The Box sync has its own project: see ~/projects/box (deploy/deploy.sh).
#
# Usage: deploy.sh [--dry-run]
# Env:   LILITH (default bis@192.168.1.202), SSH_KEY (default ~/.ssh/homelab_proxmox)
set -euo pipefail

# RETIRED 2026-11-02: the vault is replicated by Syncthing (see docs/syncthing-israfel.md) and nothing on lilith
# commits to git any more. Running this would re-enable pkm-sync.timer, so it refuses. The files stay for history.
echo "scripts/lilith/deploy.sh is retired: pkm-sync was replaced by Syncthing (docs/syncthing-israfel.md)." >&2
exit 1


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LILITH="${LILITH:-bis@192.168.1.202}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/homelab_proxmox}"
SSHO=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=8)
dry=0; [ "${1:-}" = "--dry-run" ] && dry=1

SCRIPTS=(pkm-sync.sh)
UNITS=(pkm-sync.service pkm-sync.timer)

for f in "${SCRIPTS[@]}"; do bash -n "$HERE/$f"; done

if [ $dry -eq 1 ]; then
  echo "would copy to $LILITH:~/.local/bin/ : ${SCRIPTS[*]}"
  echo "would copy to $LILITH:~/.config/systemd/user/ : ${UNITS[*]}"
  echo "would run: systemctl --user daemon-reload; systemctl --user enable --now pkm-sync.timer"
  exit 0
fi

ssh "${SSHO[@]}" "$LILITH" 'mkdir -p ~/.local/bin ~/.config/systemd/user' </dev/null
for f in "${SCRIPTS[@]}"; do scp "${SSHO[@]}" -q "$HERE/$f" "$LILITH:.local/bin/$f.new"; done
for f in "${UNITS[@]}"; do scp "${SSHO[@]}" -q "$HERE/systemd/$f" "$LILITH:.config/systemd/user/$f"; done
ssh "${SSHO[@]}" "$LILITH" 'bash -s' </dev/null <<'REMOTE'
set -euo pipefail
cd ~/.local/bin
for f in pkm-sync.sh; do chmod 755 "$f.new"; mv "$f.new" "$f"; done
systemctl --user daemon-reload
systemctl --user enable --now pkm-sync.timer
systemctl --user list-timers --no-pager | grep -E "pkm-sync" || true
REMOTE
echo "deployed."
