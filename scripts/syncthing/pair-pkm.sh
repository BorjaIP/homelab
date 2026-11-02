#!/bin/bash
# Pairs israfel (the hub), lilith and the Windows PC and shares the PKM vault folder between them, from the PC.
# It reads the israfel and lilith device IDs from the instances, takes the PC's from PC_ID below, and applies
# configure_pkm.py on israfel and lilith over ssh. The PC side is configured by its own repo (chezmoi).
# Idempotent. The API keys never leave their hosts; only device IDs (not secret) travel.
#
# Usage: pair-pkm.sh [--dry-run]
# Env:   ISRAFEL (default israfel-nfs, a Host in ~/.ssh/config), LILITH (default bis@192.168.1.202),
#        SSH_KEY (default ~/.ssh/homelab_proxmox, used for lilith)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/configure_pkm.py"
ISRAFEL="${ISRAFEL:-israfel-nfs}"
LILITH="${LILITH:-bis@192.168.1.202}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/homelab_proxmox}"

ISRAFEL_CONFIG=/var/lib/syncthing/.local/state/syncthing/config.xml
ISRAFEL_PATH=/mnt/storage/PKM
ISRAFEL_ADDR=tcp://192.168.1.207:22000
LILITH_CONFIG='$HOME/.local/state/syncthing/config.xml'
LILITH_PATH=/home/bis/pkm/pkm
LILITH_ADDR=tcp://192.168.1.202:22000
# The Windows PC (device ID printed by its own Syncthing; an ID is public, not a secret). It dials the hub itself,
# so "dynamic" is enough: local discovery on the LAN finds it, and over Tailscale it connects out to the hub.
PC_ID=BNJ2MQC-NAITLTS-7BRKZ2Y-ISBP47J-4SD2CRZ-BE6QMNR-YJJ3V6I-JWVCOAL
PC_NAME=pc
PC_ADDR=dynamic
VERSION_DAYS=90   # the hub keeps replaced and deleted files for this long

dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

python3 -I -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$TOOL"

# run_on HOST ARGS...: runs configure_pkm.py on the host with its source on stdin
run_on() {
  local host="$1"; shift
  local args; args=$(printf ' %q' "$@")
  # Arguments are %q-quoted, so the one that needs the remote $HOME is passed unquoted by the caller as @HOME@.
  args=${args//@HOME@/\$HOME}
  if [ "$host" = israfel ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=8 -o IdentityAgent=none "$ISRAFEL" "python3 - $args" < "$TOOL"
  else
    ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=8 "$LILITH" "python3 - $args" < "$TOOL"
  fi
}

if [ $dry -eq 1 ]; then
  echo "would read the device ID of israfel and lilith (python3 configure_pkm.py --print-id on each)"
  echo "would apply on israfel: share $ISRAFEL_PATH with lilith at $LILITH_ADDR and $PC_NAME ($PC_ADDR), ignore permissions (NTFS), staggered versioning $VERSION_DAYS days"
  echo "would apply on lilith:  share $LILITH_PATH with israfel at $ISRAFEL_ADDR and $PC_NAME ($PC_ADDR)"
  echo "--- what the tool itself prints in --dry-run (fake IDs):"
  python3 -I "$TOOL" --config /dev/null --dry-run --path "$ISRAFEL_PATH" --ignore-perms --staggered-days "$VERSION_DAYS" \
    --peer "LILITH-ID-0000000,lilith,$LILITH_ADDR" 2>/dev/null || true
  exit 0
fi

id_isr=$(run_on israfel --config "$ISRAFEL_CONFIG" --print-id)
id_lil=$(run_on lilith --config "@HOME@/.local/state/syncthing/config.xml" --print-id)
[ -n "$id_isr" ] && [ -n "$id_lil" ] && [ "$id_isr" != "$id_lil" ] || { echo "pair-pkm: could not read two different device IDs" >&2; exit 1; }
echo "israfel ${id_isr%%-*}...  lilith ${id_lil%%-*}..."

run_on israfel --config "$ISRAFEL_CONFIG" --path "$ISRAFEL_PATH" --ignore-perms --staggered-days "$VERSION_DAYS" \
  --peer "$id_lil,lilith,$LILITH_ADDR" --peer "$PC_ID,$PC_NAME,$PC_ADDR"
run_on lilith --config "@HOME@/.local/state/syncthing/config.xml" --path "$LILITH_PATH" \
  --peer "$id_isr,israfel,$ISRAFEL_ADDR" --peer "$PC_ID,$PC_NAME,$PC_ADDR"
