#!/bin/bash
# Applies the Syncthing settings that live in this repo to the running instance on israfel, through its REST
# API. Idempotent: running it again changes nothing. Run it as root on israfel (deploy.sh does it).
#
#   - GUI on the LAN address with TLS and a user/password. The password is generated the first time and
#     written to $LOGIN_FILE (mode 600); it is never printed.
#   - Global discovery, relays and NAT traversal off: this cluster only runs on the LAN or over Tailscale.
#
# Usage: configure-syncthing.sh [--dry-run]
# Env:   SYNC_USER (default syncthing), SYNC_GUI_ADDR (default 192.168.1.207:8384), SYNC_GUI_USER (default borja),
#        LOGIN_FILE (default /root/syncthing-gui-login.txt)
set -euo pipefail

SYNC_USER="${SYNC_USER:-syncthing}"
SYNC_GUI_ADDR="${SYNC_GUI_ADDR:-192.168.1.207:8384}"
SYNC_GUI_USER="${SYNC_GUI_USER:-borja}"
LOGIN_FILE="${LOGIN_FILE:-/root/syncthing-gui-login.txt}"
CONFIG="/var/lib/$SYNC_USER/.local/state/syncthing/config.xml"
SERVICE="syncthing@${SYNC_USER}.service"

dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

die() { echo "configure-syncthing: $*" >&2; exit 1; }

if [ $dry -eq 1 ]; then
  echo "would read the API key from $CONFIG (never printed)"
  echo "would PATCH /rest/config/options : globalAnnounceEnabled=false relaysEnabled=false natEnabled=false"
  echo "would PATCH /rest/config/gui : user=$SYNC_GUI_USER, a generated password written to $LOGIN_FILE (mode 600), tls=true"
  echo "would PATCH /rest/config/gui : address=$SYNC_GUI_ADDR (last, it moves the listener)"
  echo "would check that the stored password is a bcrypt hash and that the GUI answers on https://$SYNC_GUI_ADDR"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "run as root"
systemctl is-active --quiet "$SERVICE" || die "$SERVICE is not running"
[ -r "$CONFIG" ] || die "cannot read $CONFIG"

# Current GUI address (the first call goes to wherever the GUI listens now) and API key, both read from the config.
read -r CUR_ADDR APIKEY < <(python3 - "$CONFIG" <<'PY'
import sys, xml.etree.ElementTree as ET
g = ET.parse(sys.argv[1]).getroot().find("gui")
print(g.findtext("address"), g.findtext("apikey"))
PY
)
[ -n "$APIKEY" ] || die "no API key in $CONFIG"
tls_now=$(python3 -c "import sys,xml.etree.ElementTree as ET;print(ET.parse(sys.argv[1]).getroot().find('gui').get('tls'))" "$CONFIG")
scheme=http; [ "$tls_now" = "true" ] && scheme=https

api() { # api METHOD PATH [json]; stdout stays silent, the key never reaches the process list output
  local method="$1" path="$2" body="${3:-}"
  local args=(-sk -o /dev/null -w '%{http_code}' -X "$method" -H "X-API-Key: $APIKEY" -H 'Content-Type: application/json')
  [ -n "$body" ] && args+=(--data "$body")
  local code
  code=$(curl "${args[@]}" "$scheme://$CUR_ADDR$path")
  case "$code" in 2??) ;; *) die "$method $path -> HTTP $code" ;; esac
}

echo "==> options: no global discovery, relays or NAT traversal"
api PATCH /rest/config/options '{"globalAnnounceEnabled":false,"relaysEnabled":false,"natEnabled":false}'

echo "==> GUI credentials"
if [ ! -s "$LOGIN_FILE" ]; then
  umask 077
  pw=$(head -c 24 /dev/urandom | base64 | tr -d '=+/\n' | head -c 24)
  printf 'username: %s\npassword: %s\n' "$SYNC_GUI_USER" "$pw" > "$LOGIN_FILE"
  body=$(python3 -c "import json,sys;print(json.dumps({'user':sys.argv[1],'password':sys.argv[2]}))" "$SYNC_GUI_USER" "$pw")
  api PATCH /rest/config/gui "$body"
  echo "new password written to $LOGIN_FILE"
else
  echo "keeping the existing password ($LOGIN_FILE)"
fi

echo "==> GUI on $SYNC_GUI_ADDR with TLS"
api PATCH /rest/config/gui "{\"useTLS\":true,\"address\":\"$SYNC_GUI_ADDR\"}"
sleep 3

# The API ignores unknown JSON fields without an error, so check what was really stored.
tls_after=$(python3 -c "import sys,xml.etree.ElementTree as ET;print(ET.parse(sys.argv[1]).getroot().find('gui').get('tls'))" "$CONFIG")
[ "$tls_after" = "true" ] || die "GUI TLS was not enabled (config says tls=$tls_after)"
addr_after=$(python3 -c "import sys,xml.etree.ElementTree as ET;print(ET.parse(sys.argv[1]).getroot().find('gui').findtext('address'))" "$CONFIG")
[ "$addr_after" = "$SYNC_GUI_ADDR" ] || die "GUI address was not changed (config says $addr_after)"

stored=$(python3 -c "import sys,xml.etree.ElementTree as ET;print(ET.parse(sys.argv[1]).getroot().find('gui').findtext('password') or '')" "$CONFIG")
case "$stored" in '$2'*) echo "stored password is a bcrypt hash" ;; *) die "stored password is not hashed" ;; esac

anon=$(curl -sk -o /dev/null -w '%{http_code}' "https://$SYNC_GUI_ADDR/rest/system/status" || true)
echo "GUI without credentials -> HTTP $anon (must be 401 or 403)"
case "$anon" in 401|403) ;; *) die "GUI answers without credentials" ;; esac
echo "Done. Open https://$SYNC_GUI_ADDR (self-signed certificate: the browser warns once). Login: $LOGIN_FILE"
