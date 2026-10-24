#!/bin/bash
# Launches the Proxmox MCP server (stdio) with credentials from terraform/.env.
# Claude Code runs this script, so no secret is stored in Claude's config.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.6.6"

# GUI-launched clients may not have ~/.local/bin (where uvx lives) in PATH.
export PATH="${HOME}/.local/bin:${PATH}"

# Credentials: the Terraform .env (same PROXMOX_* variables). PROXMOX_MCP_ENV_FILE overrides the path.
ENV_FILE="${PROXMOX_MCP_ENV_FILE:-${ROOT}/terraform/.env}"

if [ ! -f "${ENV_FILE}" ]; then
    echo "Missing credentials: expected ${ENV_FILE}" >&2
    exit 1
fi

# Read only the variables the server needs. The file is parsed, never sourced: the Terraform
# .env defines other variables (e.g. UID) that must not be executed or exported.
while IFS= read -r line || [ -n "${line}" ]; do
    line="${line#export }"
    if [[ "${line}" =~ ^(PROXMOX_[A-Z_]+|MCP_[A-Z_]+|LOG_LEVEL)=(.*)$ ]]; then
        value="${BASH_REMATCH[2]}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        export "${BASH_REMATCH[1]}=${value}"
    fi
done < "${ENV_FILE}"

# .env uses PROXMOX_USER=user@realm!tokenname and PROXMOX_PASS=<token secret>;
# the server expects them split into user, token name and token value.
if [[ "${PROXMOX_USER:-}" == *'!'* ]]; then
    PROXMOX_TOKEN_NAME="${PROXMOX_USER#*!}"
    PROXMOX_USER="${PROXMOX_USER%%!*}"
fi
PROXMOX_TOKEN_VALUE="${PROXMOX_PASS:-${PROXMOX_TOKEN_VALUE:-}}"
export PROXMOX_USER PROXMOX_TOKEN_NAME PROXMOX_TOKEN_VALUE

exec uvx "proxmox-mcp-plus==${VERSION}"
