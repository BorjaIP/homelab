# Proxmox SSH Access (dedicated key)

How the SSH access to the Proxmox host is set up for automation (backups, upgrade), and how to
rebuild it if it breaks. A **dedicated key** is used so it can be revoked without touching any
other access.

| Item | Value |
|------|-------|
| Host | `server-origin`, `192.168.1.111` |
| User | `root` (the backup script and `/etc/pve/priv` need root) |
| Private key | `~/.ssh/homelab_proxmox` on the workstation (WSL), mode `600`, **never in git** |
| Public key | `~/.ssh/homelab_proxmox.pub`, comment `claude-homelab-proxmox <date>` |
| Type | ed25519, no passphrase (so automation can use it unattended) |

Every command run through this key is shown to the owner and approved before it runs.

## 1. Create the key (workstation)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/homelab_proxmox -N "" -C "claude-homelab-proxmox $(date +%F)"
chmod 600 ~/.ssh/homelab_proxmox
cat ~/.ssh/homelab_proxmox.pub
```

A key without a passphrase can be used by anything running as your user, so keep the file at
mode `600` and do not copy it around. If you prefer a passphrase, add the key to `ssh-agent`
before each session instead.

## 2. Install the public key on Proxmox

On the Proxmox host (web console: node → *Shell*, or a session you already have), as root:

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo 'ssh-ed25519 AAAA... claude-homelab-proxmox <date>' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

Paste the **whole line** of the `.pub` file in place of the example. On Proxmox,
`/root/.ssh/authorized_keys` is normally a symlink to `/etc/pve/priv/authorized_keys`; appending
to it works the same.

Check that root key login is allowed (Proxmox default is `prohibit-password`, which accepts keys):

```bash
grep -E '^\s*PermitRootLogin' /etc/ssh/sshd_config
```

## 3. Test from the workstation

```bash
ssh -i ~/.ssh/homelab_proxmox -o IdentitiesOnly=yes root@192.168.1.111 'hostname; pveversion'
```

`IdentitiesOnly=yes` makes ssh offer only this key. The first connection asks to trust the host
key; compare the fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the host.

Optional `~/.ssh/config` entry so the command is shorter:

```
Host proxmox
    HostName 192.168.1.111
    User root
    IdentityFile ~/.ssh/homelab_proxmox
    IdentitiesOnly yes
```

## 4. Tighten it (optional)

Prefix the key line in `authorized_keys` with options to limit where it works from:

```
from="<workstation-IP>" ssh-ed25519 AAAA... claude-homelab-proxmox <date>
```

Do **not** add `command="..."` if the key must also be used for the upgrade: it forces one command
and blocks everything else.

## Revoke or rotate

On the Proxmox host, delete the line whose comment is `claude-homelab-proxmox`:

```bash
sed -i '/claude-homelab-proxmox/d' /root/.ssh/authorized_keys
```

Then create a new key (step 1) and install it (step 2). Do this whenever the workstation or the
private key may have been exposed.

## If it breaks

| Symptom | Cause / fix |
|---------|-------------|
| `Permission denied (publickey)` | Wrong line pasted, or modes wrong: `/root/.ssh` must be `700` and `authorized_keys` `600`. Re-paste the full `.pub` line. |
| Key works from the console but not remotely | `PermitRootLogin` is `no` in `/etc/ssh/sshd_config`; set `prohibit-password` and `systemctl reload ssh`. |
| Private key lost | Generate a new one (step 1), install it (step 2), remove the old line (Revoke). The key is not recoverable. |
| Host key changed warning | Expected after reinstalling Proxmox: `ssh-keygen -R 192.168.1.111`, then check the new fingerprint before trusting it. |
| Locked out of SSH entirely | Use the Proxmox web console (node → *Shell*) or the physical console to fix `authorized_keys`. |
