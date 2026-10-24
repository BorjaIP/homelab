# MCP Servers

MCP servers that Claude Code uses to operate the homelab. The launcher scripts live in `scripts/`;
secrets stay in the git-ignored `terraform/.env`.

## Proxmox (ProxmoxMCP-Plus)

- **Project**: [RekklesNA/ProxmoxMCP-Plus](https://github.com/RekklesNA/ProxmoxMCP-Plus) (MIT),
  PyPI package `proxmox-mcp-plus`.
- **Pinned version**: `0.6.6`, set in `scripts/proxmox-mcp.sh`. Bump it deliberately after reading the release notes.
- **Transport**: stdio, launched on demand by Claude Code through `uvx`. No container or daemon.
- **Config**: environment variables only. With no config file, the server falls back to
  `PROXMOX_*` variables, so no `config.json` is needed.

### Files

| File | Purpose |
|------|---------|
| `scripts/proxmox-mcp.sh` | Loads the credentials and runs the server. This is what Claude Code executes. |
| `terraform/.env` | The real values, shared with Terraform. **Git-ignored.** `PROXMOX_MCP_ENV_FILE` points the wrapper to another file. |

### 1. Create the user and a least-privilege API token (on the Proxmox host)

One identity, `claude`, is used for both SSH (Linux user) and the MCP (`claude@pam` + token).
See "Claude user for SSH and the MCP" below for the SSH side.

```bash
pveum user add claude@pam
pveum acl modify / -user claude@pam -role PVEAuditor
pveum user token add claude@pam mcp --privsep 1
pveum acl modify / -token 'claude@pam!mcp' -role PVEAuditor
pveum user token permissions claude@pam mcp
```

The secret is shown only once. With `--privsep 1` a token can never hold a permission its user
lacks, so the role must be granted to **both** the user and the token. `PVEAuditor` is
read-only; to let the MCP create snapshots or backups, grant `PVEVMAdmin` / `PVEDatastoreUser`
on both, only on the paths that need it. The last command shows the token's effective rights.

### 2. Fill in `terraform/.env`

The wrapper reads `terraform/.env`, so the credentials already used by Terraform are reused
without a second copy (the older `mcp/` folder with its own `.env` no longer exists). It accepts
the same variable names used elsewhere in the homelab:

```bash
PROXMOX_HOST=192.168.1.X
PROXMOX_PORT=8006
PROXMOX_VERIFY_SSL=true
PROXMOX_USER=user@pam!tokenname   # user and token name in one value
PROXMOX_PASS=token-secret         # the API token secret, not a password
```

`scripts/proxmox-mcp.sh` splits `PROXMOX_USER` at the `!` into the user and the token name, and maps
`PROXMOX_PASS` to the server's `PROXMOX_TOKEN_VALUE`. The server only supports API tokens, so
`PROXMOX_PASS` must be a token secret and never an account password. Optional:
`MCP_TOOL_ALLOWLIST=get_nodes,get_vms,get_containers,get_storage` limits the exposed tools.

### 3. Register it in Claude Code

```bash
claude mcp add -s local proxmox -- /home/borja/projects/homelab/scripts/proxmox-mcp.sh
```

Then restart Claude Code and check it with `claude mcp list`. The `proxmox` server should
appear as connected, with tools such as `get_nodes` and `get_vms`.

### Remove or update

```bash
claude mcp remove proxmox
```

To update, change `VERSION` in `scripts/proxmox-mcp.sh` and restart Claude Code.

The server keeps a small job-tracking database, `proxmox-jobs.sqlite3`, in the folder it is started
from (the repo root). It is git-ignored; it is empty unless the MCP creates backups or other long
tasks. `PROXMOX_JOBS_SQLITE_PATH` moves it elsewhere.

### Claude user for SSH and the MCP

The Linux user `claude` on the Proxmox host is what makes `claude@pam` valid (the `pam` realm
authenticates against Linux users). Run on the host as root.

**1. Generate a dedicated key (on your machine, with a passphrase):**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/proxmox_claude -C claude-mcp
```

**2. Create the user and authorize the key (on the host):**

```bash
adduser --disabled-password --gecos "" claude
install -d -m 700 -o claude -g claude /home/claude/.ssh
echo "PASTE_CONTENT_OF_proxmox_claude.pub" > /home/claude/.ssh/authorized_keys
chown claude:claude /home/claude/.ssh/authorized_keys && chmod 600 /home/claude/.ssh/authorized_keys
```

**3. Allow only the upgrade commands through sudo (install `sudo` first if missing):**

```bash
apt install -y sudo
visudo -f /etc/sudoers.d/claude
```

```
claude ALL=(root) NOPASSWD: /usr/bin/apt-get update, /usr/bin/apt-get -y dist-upgrade, /usr/bin/pveversion
```

`dist-upgrade` runs package scripts as root, so this is effectively root access. Remove it
when the upgrade is done:

```bash
rm /etc/sudoers.d/claude
```

**4. Test from your machine:**

```bash
ssh -i ~/.ssh/proxmox_claude claude@<PROXMOX_HOST> 'sudo pveversion'
```

### Scope and limits

- The MCP talks to the Proxmox **API**. It cannot run `apt dist-upgrade` on the host; upgrading
  Proxmox itself is done over SSH.
- Node SSH and container command execution are off by default and need an extra `ssh` config.
  They are not enabled here.
- To limit what Claude can call, set `MCP_TOOL_ALLOWLIST` in `terraform/.env`.
