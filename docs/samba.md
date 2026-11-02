# Samba (Windows access to the NAS)

How Windows reaches the shared disk (`Z:`), why it is built this way, and how it is secured.

## How it is built

```
Windows (Z:) ──SMB3──▶ tabris: container "samba" (network_mode: host, share [Storage])
                          │ /mnt/storage = NFSv3 mount
                          ▼
                       israfel (NFS server) ──ntfs-3g──▶ WD Elements USB disk (NTFS)
```

- Only **tabris** (VM 217, `192.168.1.217`) runs Samba, as the container `samba` of
  [`terraform/docker/tabris/docker-compose.yaml`](../terraform/docker/tabris/docker-compose.yaml).
  Terraform/`setup.sh` recreate it with the VM, nothing is installed by hand.
- Image: [`ghcr.io/servercontainers/samba`](https://github.com/ServerContainers/samba), tag
  `smbd-only-a3.24.3-s4.23.8-r0` (Alpine 3.24.3, Samba 4.23.8, smbd only: no wsdd2/avahi, because
  the drive is mapped by IP). The tag is pinned like the other images; bump it on purpose.
- The share `[Storage]` exposes the whole disk (`Backups`, `Calibre`, `Documents`, `images`,
  `Media`, `Photos`, `Transmission`). israfel itself has no Samba, only NFS, see
  [israfel-nfs.md](israfel-nfs.md).
- `\\tabris\Storage` does not work: NetBIOS is off and Windows has no DNS entry for the name.
  Use the IP, `\\192.168.1.217\Storage`.
- Do not install the system `smbd`/`nmbd` on tabris: the container uses the host network and
  both compete for port 445.

## Configuration of the container

| Setting | Value | Why |
|---------|-------|-----|
| Account | `ACCOUNT_${SAMBA_USER}=${SAMBA_PASS}` | User and password come from the VM's `.env`, never written in the repo |
| File owner | `UID_${SAMBA_USER}=1001` | Files are written as `bis` (1001), not as root: the NFS export squashes root. No change to the export is needed |
| Guests | `map to guest = Never`, `guest ok = no`, `valid users`, `restrict anonymous = 2` | A login is required; an unknown user is refused |
| Protocol | `server min protocol = SMB3`, `server signing = mandatory`, `disable netbios = yes` | Windows 11 expects signing; no old protocols |
| Oplocks | `oplocks`, `level2 oplocks`, `kernel oplocks` = no | The disk is shared with other NFS clients (Immich, Jellyfin, Transmission...), and caching leases cannot be kept coherent with them |
| Mac modules | `vfs objects =` (empty, in the share) | The image enables `catia fruit streams_xattr` by default; NFSv3 has no extended attributes |
| Masks | `create mask 0664`, `directory mask 0775` | NTFS-3G ignores them; saner defaults |
| `System Volume Information` | `veto files` hides it | Windows' own folder on the NTFS disk |
| `images` | `veto files` hides it | Created by Proxmox, see below |

Environment variable syntax of the image: `SAMBA_GLOBAL_CONFIG_<key>=<value>` with spaces of the
key written as `_SPACE_` (`SAMBA_GLOBAL_CONFIG_server_SPACE_min_SPACE_protocol=SMB3`);
`SAMBA_VOLUME_CONFIG_<name>` holds a whole share, lines separated by `;`. The container prints the
generated `smb.conf` at start: `docker logs samba`.

### Why `images/` exists at the root of the disk

`/mnt/storage/images` is not created by any container or by this repo. Proxmox creates it: the NFS
storage `nfs-storage` (`/etc/pve/storage.cfg` on the Proxmox host, export `/mnt/storage` of israfel)
has `content images` ("Disk image"), and Proxmox makes one folder per content type at the root of
every storage it activates (`images/` for disk images, `dump/` for backups, `template/iso/` for ISOs,
`snippets/` for snippets). At least one content type is mandatory, so some folder always appears.
It is empty because the VM disks live on `local-lvm`.

- Deleting it is pointless: Proxmox recreates it when the storage is activated again (reboot,
  remount, `pvestatd`).
- The storage cannot be removed: `bk-israfel`, `bk-leliel` and `bk-lilith` are `dir` storages under
  `/mnt/pve/nfs-storage/Backups/...` and need that mount.
- It is hidden from Windows with `veto files`, which also makes it undeletable over SMB. Do not
  put real data in it.

## Deploy on tabris

1. Check the plan: `tofu plan -target='module.vms["tabris"]'`. Only the compose provisioner of
   tabris is replaced.
2. Apply it. `docker compose up -d` creates the `samba` container.

## Verify on tabris

- The container is `healthy` and its log shows `smbd 4.23.8 started`.
- A login as `bis` lists the whole disk without `System Volume Information`.
- Creating a folder and uploading a file works.
- A guest login gets `NT_STATUS_ACCESS_DENIED`.
- Files appear as `0:0 rwxrwxrwx` on the NFS mount: that is how NTFS-3G presents everything, not
  an error.

## Mapping `Z:` in Windows

Use the IP and the account `bis` with the password `SAMBA_PASS` of the VM's `.env` (not the Windows
one). The backup scripts read `Z:\...`, so the mapping has to survive a reboot without a prompt.
In a normal (not elevated) PowerShell or CMD:

```
net use * /delete
cmdkey /add:192.168.1.217 /user:bis /pass
net use Z: \\192.168.1.217\Storage /persistent:yes
```

- `cmdkey ... /pass` asks for the password and stores it in Windows Credential Manager, so the
  `net use` that follows (and every reconnect after a reboot) needs no prompt.
- Do **not** use `net use Z: ... /user:bis * /savecred`: Windows refuses `*` together with
  `/savecred` (`System error 3510: a command was used with conflicting switches`).
- Error 1219 (multiple connections with different credentials to the same server): run
  `net use * /delete` and map again.
- Check with `dir Z:\Photos\library\admin` and `dir Z:\Documents\borja\files`.
- A drive mapped in a normal session is not visible to an *elevated* PowerShell unless it is mapped
  there too (or `EnableLinkedConnections=1` is set in the registry). Run the backup scripts from
  the same kind of session where `Z:` was mapped.

## Rebuilding tabris

Nothing manual: Terraform recreates the VM and `setup.sh` starts the container with the account
from `.env`. The data lives on the israfel disk.

## Changing the image version

Set the new (or an older) image tag in the compose file and apply it as in "Deploy on tabris".
