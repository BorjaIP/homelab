# Syncthing on israfel

Israfel is the always-on hub of a Syncthing cluster (Syncthing 2.1.7): the PC and lilith each run their own
Syncthing and share folders with it. Syncthing syncs local folders; it is not a network file system, so it must
not be pointed at an NFS mount. Scripts: `scripts/israfel/`.

## Why native and not Docker

israfel has 2 vCPU, 4 GB RAM (573 MB used, 3.3 GB available, the rest is disk cache) and a **3.9 GB root disk
with 1.4 GB free**. Docker is not installed and its storage does not belong on the NTFS data disk (`ntfs-3g`,
mounted `fuseblk` as root with open permissions). Syncthing from the official apt repository is a few tens of MB.

## Install and configure

```bash
scripts/israfel/test-install-syncthing.sh     # offline checks, touch nothing
scripts/israfel/deploy.sh --dry-run           # prints what would happen
scripts/israfel/deploy.sh                     # install, then configure, on israfel-nfs (both are idempotent)
scripts/israfel/deploy.sh --only configure    # re-apply only the settings
```

`install-syncthing.sh` adds the official repository (`stable-v2`, signed key from syncthing.net, pinned at 990),
installs `syncthing`, creates the system user `syncthing`, creates `/mnt/storage/PKM` (refuses to if `/mnt/storage`
is not mounted) and enables `syncthing@syncthing.service` with a drop-in: `RequiresMountsFor=/mnt/storage`,
`GOMAXPROCS=1`, `MemoryMax=512M`.

`configure-syncthing.sh` applies, through the REST API, the settings that belong to this repo, and checks the
result in `config.xml` (the API ignores unknown JSON fields without an error, so the check is needed):

| Setting | Value | Why |
|---|---|---|
| GUI address | `192.168.1.207:8384`, TLS on | Reachable from the LAN and over Tailscale; plain HTTP redirects to HTTPS |
| GUI login | user `borja`, generated password in `/root/syncthing-gui-login.txt` (mode 600), stored as bcrypt | The password is never printed or committed |
| Global discovery, relays, NAT traversal | off | The cluster only runs on the LAN or over Tailscale |
| Local discovery | on (default) | Finds the PC and lilith on the LAN |

Devices, folders and their types are not managed by these scripts; see "Vault sync".

## Web interface

Open `https://192.168.1.207:8384`. The certificate is self-signed, so the browser warns once. Read the login with

```bash
ssh israfel-nfs 'cat /root/syncthing-gui-login.txt'
```

Configuration lives in `/var/lib/syncthing/.local/state/syncthing/config.xml`. The GUI and the REST API
(`X-API-Key`, read from that file by the scripts) edit the same configuration. Keep the API key and device IDs
out of the repo. Port 22000 (TCP and UDP) listens on all interfaces for the other devices; `ufw` is inactive.

## Vault sync

Two-way replication of the vault folder `pkm/pkm` between lilith, israfel (hub) and the Windows PC. Git commits
come only from Obsidian, as `AGENTS.md` says. See `pkm-unification.md` D3 for the design decision.

| Item | Value |
|---|---|
| Folder | id `pkm-vault`, label `pkm`, type send and receive on every device |
| israfel | `/mnt/storage/PKM`, ignore permissions (NTFS), staggered versioning 90 days |
| lilith | `/home/bis/pkm/pkm` |
| PC | `E:\Documents\pkm\pkm`, device `pc` (ID in `scripts/syncthing/pair-pkm.sh`), Syncthing 2.1.7. Its own side (install, folder, firewall, git excludes) lives in the owner's chezmoi repo, not here. It ignores `.obsidian` and `.claude` |
| Ignored (`.stignore` via API) | `.obsidian`. `.git` is outside the folder, so it never travels |
| Peers' addresses | static `tcp://192.168.1.207:22000` and `tcp://192.168.1.202:22000` (discovery is off); the `pc` device has address `dynamic` (the PC dials the hub) |

`meridian/` (project notes) travels with the vault; `.claude/` (Claudian plugin data) does not.

### Apply or re-apply

```bash
scripts/syncthing/pair-pkm.sh --dry-run      # first
scripts/syncthing/pair-pkm.sh
```

The script reads each device ID from the instance and calls `scripts/syncthing/configure_pkm.py` over ssh, which
reads every value back and fails when the instance stored something else.

### Verify

- Every device reports `idle`, the same number of files, 0 needed, 0 errors, 0 conflicts.
- Tests: `python3 -I scripts/syncthing/test_configure_pkm.py` (9, against a stand-in REST server).

## Things to know

- **It is replication with history, not a backup.** Deletions and overwrites propagate. The hub keeps replaced
  and deleted files in `.stversions` for 90 days. All copies are on the same LAN; the data disk of israfel is
  not in `vzdump`, and `private/` and `wiki/` are not in git.
- **`private/` is visible over NFS.** `/mnt/storage` is exported to `192.168.1.0/24` read-write, so any machine
  that mounts it can read `/mnt/storage/PKM/private`. The owner accepts this.
- **Conflicts** appear as `*.sync-conflict-*` files inside the vault when two devices edit the same file at once.
- **Names.** Characters Windows rejects (`: ? * " < > |`, trailing space or dot) would break the PC and NTFS side.
  None exist today.
- **Git on the clones.** `.stfolder`, `.stignore`, `.stversions` and conflict files are excluded through
  `.git/info/exclude`. On lilith never run `git checkout -- pkm/`, `git clean` or `git reset --hard`: they would
  overwrite files that are being replicated.
- **Leak gate.** Run `python3 .claude/scripts/lint.py --leaks --staged` on the PC before committing what Hermes
  wrote.
