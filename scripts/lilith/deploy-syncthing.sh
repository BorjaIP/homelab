#!/bin/bash
# Copies install-syncthing.sh to lilith and runs it there as bis. Run it from the PC.
# Nothing changes with --dry-run: it only prints what would happen.
#
# Usage: deploy-syncthing.sh [--dry-run]
# Env:   LILITH (default bis@192.168.1.202), SSH_KEY (default ~/.ssh/homelab_proxmox)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LILITH="${LILITH:-bis@192.168.1.202}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/homelab_proxmox}"
SSHO=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=8)

case "${1:-}" in
  "") dry=0 ;;
  --dry-run) dry=1 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

bash -n "$HERE/install-syncthing.sh"

if [ $dry -eq 1 ]; then
  echo "would copy install-syncthing.sh to $LILITH:~/.local/bin/install-syncthing.sh"
  echo "would run on $LILITH: bash ~/.local/bin/install-syncthing.sh"
  echo "--- what the script itself would do:"
  bash "$HERE/install-syncthing.sh" --dry-run
  exit 0
fi

ssh "${SSHO[@]}" "$LILITH" 'mkdir -p ~/.local/bin' </dev/null
scp "${SSHO[@]}" -q "$HERE/install-syncthing.sh" "$LILITH:.local/bin/install-syncthing.sh"
ssh "${SSHO[@]}" "$LILITH" 'bash ~/.local/bin/install-syncthing.sh' </dev/null
