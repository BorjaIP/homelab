#!/bin/bash
# Installs, or rebuilds, the Glances web server on the Proxmox host. Run as root ON the host.
#
# Glances lives in a Python virtualenv, and a virtualenv is tied to the system Python version.
# After a Debian major upgrade (bookworm 3.11 -> trixie 3.13) the venv breaks with
# "No module named glances". Re-run this script after every such upgrade.
#
# The Homepage widgets (terraform/docker/matarael/widgets.yaml) read http://<host>:61208 with the
# Glances API version 4: CPU, memory and CPU temperature.
#
# Usage: proxmox-glances-setup.sh                latest Glances 4.x
#        GLANCES_SPEC='glances[web]==4.3.1' proxmox-glances-setup.sh      pin a version
set -euo pipefail

DIR="/root/glances"
VENV="${DIR}/venv"
UNIT="/etc/systemd/system/glances.service"
GLANCES_SPEC="${GLANCES_SPEC:-glances[web]}"
PORT=61208

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root on the Proxmox host." >&2
    exit 1
fi

log "Installing python3-venv"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv

mkdir -p "${DIR}"
if [ -d "${VENV}" ]; then
    log "Keeping the previous venv as ${VENV}.old (delete it once Glances works)"
    rm -rf "${VENV}.old"
    mv "${VENV}" "${VENV}.old"
fi

log "Creating the venv with $(python3 --version)"
python3 -m venv "${VENV}"
"${VENV}/bin/pip" install --quiet --upgrade pip
log "Installing ${GLANCES_SPEC}"
"${VENV}/bin/pip" install --quiet "${GLANCES_SPEC}"
"${VENV}/bin/pip" freeze >"${DIR}/requirements.lock"
log "Installed: $("${VENV}/bin/python" -m glances -V 2>&1 | head -1)  (full list in ${DIR}/requirements.lock)"

log "Writing ${UNIT}"
cat >"${UNIT}" <<'EOF'
[Unit]
Description=Glances Monitoring Tool
After=network.target

[Service]
ExecStart=/root/glances/venv/bin/python -m glances -w
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl reset-failed glances.service 2>/dev/null || true
systemctl enable glances.service >/dev/null 2>&1
systemctl restart glances.service

log "Waiting for the web server on port ${PORT}"
for _ in $(seq 1 20); do
    if curl -fs --max-time 3 "http://127.0.0.1:${PORT}/api/4/status" >/dev/null 2>&1; then
        log "Glances API v4 answers on port ${PORT}"
        curl -fs "http://127.0.0.1:${PORT}/api/4/cpu" | head -c 160
        echo
        exit 0
    fi
    sleep 2
done

echo "Glances did not answer on port ${PORT}. See: journalctl -u glances -n 30" >&2
exit 1
