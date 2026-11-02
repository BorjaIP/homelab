#!/bin/bash
# Copies the Syncthing scripts to israfel and runs them there as root: install first, then configure.
# Run it from the PC. Nothing changes with --dry-run: it only prints what would happen.
#
# Usage: deploy.sh [--dry-run] [--only install|configure]
# Env:   ISRAFEL (default israfel-nfs, the Host entry in ~/.ssh/config)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISRAFEL="${ISRAFEL:-israfel-nfs}"
SSHO=(-o BatchMode=yes -o ConnectTimeout=8 -o IdentityAgent=none)
dry=0; steps=(install configure)
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --only) case "${2:-}" in install|configure) steps=("$2"); shift 2 ;; *) echo "usage: $0 [--dry-run] [--only install|configure]" >&2; exit 2 ;; esac ;;
    *) echo "usage: $0 [--dry-run] [--only install|configure]" >&2; exit 2 ;;
  esac
done

for s in "${steps[@]}"; do bash -n "$HERE/$s-syncthing.sh"; done

if [ $dry -eq 1 ]; then
  for s in "${steps[@]}"; do
    echo "would copy $s-syncthing.sh to $ISRAFEL:/root/$s-syncthing.sh"
    echo "would run on $ISRAFEL: bash /root/$s-syncthing.sh"
    echo "--- what $s-syncthing.sh itself would do:"
    bash "$HERE/$s-syncthing.sh" --dry-run
  done
  exit 0
fi

for s in "${steps[@]}"; do
  scp "${SSHO[@]}" -q "$HERE/$s-syncthing.sh" "$ISRAFEL:/root/$s-syncthing.sh"
  ssh "${SSHO[@]}" "$ISRAFEL" "bash /root/$s-syncthing.sh" </dev/null
done
