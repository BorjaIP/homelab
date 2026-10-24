# Proxmox Backups (hand-made VMs + host)

Backs up everything that Packer/Terraform **cannot rebuild**. The Terraform-managed VMs are not
covered here: they are recreated from scratch and get their `~/config/` back from NFS (see
[vm-config-backups.md](vm-config-backups.md)).

| What | Why it needs a backup | Backed up as |
|------|-----------------------|--------------|
| `israfel` (VM 207) | NFS server, installed by hand. Exports, mounts and the USB disk passthrough exist only inside the VM. | `vzdump` image of the OS disk |
| `leliel` (VM 212) | Home Assistant OS, installed by hand with a helper script. Automations, devices and history live only in the VM. | `vzdump` image |
| Proxmox host (`server-origin`) | `storage.cfg`, every VM `.conf`, network, API tokens. Lost if the host is reinstalled or an upgrade goes wrong. | `tar.gz` of `/etc` + a snapshot of the runtime state |

Not included, on purpose: israfel's 3.7 TB USB data disk (`backup=0`, it is the data that the
Windows process already copies elsewhere), and the Terraform-managed VMs.

## Where it lands

Same tree as the config backups of the other VMs, one folder per machine name:

```
/mnt/storage/Backups/
├── israfel/vzdump/        vzdump-qemu-207-<date>.vma.zst  (+ .log, .notes)   keeps 3
├── leliel/vzdump/         vzdump-qemu-212-<date>.vma.zst  (+ .log, .notes)   keeps 3
└── proxmox/               pve-host_server-origin_<timestamp>.tar.gz          keeps 8
```

The Proxmox host sees that same folder as `/mnt/pve/nfs-storage/Backups` (the `nfs-storage`
storage mounts the same export). `nfs-storage` itself only has the content type `images`, so each
VM gets its own small **Directory storage** (`bk-israfel`, `bk-leliel`) pointing into its folder.
That is what makes the backups show up in the Proxmox GUI (Datacenter → Storage → Backups, with
*Restore*, notes and retention), while keeping the per-machine layout. The Proxmox MCP
(`list_backups`) returned *No backups found* on 2026-10-24 even though `pvesm list bk-leliel` and
`pvesm list bk-israfel` show them: its API token has limited privileges (it also got a 403
`Datastore.AllocateSpace` on `/storage/local`). Granting it `Datastore.Audit` (read) on
`/storage/bk-*` should fix the listing; not done yet. The host archive is a plain `tar.gz`, not a `vzdump`, so it does not appear in the GUI.

## One-time setup: the backup storages

Do it once per hand-made VM, in the GUI (Datacenter → Storage → Add → Directory) or on the host:

```bash
pvesm add dir bk-israfel --path /mnt/pve/nfs-storage/Backups/israfel \
    --content backup --content-dirs backup=vzdump \
    --prune-backups keep-last=3 --is_mountpoint /mnt/pve/nfs-storage

pvesm add dir bk-leliel --path /mnt/pve/nfs-storage/Backups/leliel \
    --content backup --content-dirs backup=vzdump \
    --prune-backups keep-last=3 --is_mountpoint /mnt/pve/nfs-storage
```

- `content-dirs backup=vzdump` makes Proxmox write to `<path>/vzdump/` instead of `<path>/dump/`.
- `is_mountpoint` marks the storage offline when the NFS is not mounted, so a backup fails instead
  of silently filling the host's local disk. Accepted with a path as value on Proxmox 8.4.1
  (checked); the script also checks the mount itself.
- The storage name must be `bk-<VM name>`: that is how the script finds it.

## Run it

The script lives in [`scripts/proxmox-backup.sh`](../scripts/proxmox-backup.sh) and runs **on the Proxmox host as
root**:

```bash
scp scripts/proxmox-backup.sh root@<proxmox-host>:/root/proxmox-backup.sh
ssh root@<proxmox-host> 'bash /root/proxmox-backup.sh'          # everything
ssh root@<proxmox-host> 'bash /root/proxmox-backup.sh vms'      # only israfel and leliel
ssh root@<proxmox-host> 'bash /root/proxmox-backup.sh host'     # only the host config
```

What it does, in order:

1. Refuses to run if it is not root, `vzdump` is missing, `/mnt/pve/nfs-storage` is not mounted or
   `Backups/` does not exist there (so a missing mount never fills the host's local disk).
2. For each VM in `MANUAL_VMS`: reads its name from `qm config`, checks that the storage
   `bk-<name>` exists and is online, and runs `vzdump --storage bk-<name> --mode snapshot
   --compress zstd` (no downtime, uses the guest agent).
3. Packs the whole `/etc` (it includes `/etc/pve`: `storage.cfg`, `jobs.cfg`, every VM `.conf`)
   and root's crontabs, plus an `info/` folder (`pveversion -v`, `pvesm status`, `qm list`,
   `pct list`, `lsblk`, `blkid`, `ip -br addr`, `dpkg --get-selections`, `apt-mark showmanual`)
   into `Backups/proxmox/`.
4. Deletes old backups **only after** the new one succeeded (keeps the newest 3 per VM, 8 for the
   host). Change `KEEP_VZDUMP` / `KEEP_HOST` at the top of the script.

Adding another hand-made VM later: add its ID to `MANUAL_VMS` and create its `bk-<name>` storage.

The VM backups can also be started from the GUI (VM → Backup → Backup now, storage `bk-<name>`).

## Before a Proxmox upgrade

1. `bash /root/proxmox-backup.sh` and check that the three outputs exist and are not empty.
2. Check the VM backups are readable: `zstd -t Backups/<name>/vzdump/*.vma.zst`.
3. Make sure the Windows process has copied `Backups/` to the other disk.
4. Upgrade (run the version's checker first, e.g. `pve8to9 --full` for 8 → 9).

## Restore

### A VM (israfel or leliel)

GUI: Datacenter → `bk-leliel` → Backups → pick the file → *Restore*. Or from the host:

```bash
# Pick the file; restore onto local-lvm, same ID as before
qmrestore /mnt/pve/nfs-storage/Backups/leliel/vzdump/vzdump-qemu-212-<date>.vma.zst 212 --storage local-lvm
qm config 212          # compare with the backed-up config before starting it
qm start 212
```

For **israfel**, the USB data disk is not part of the image. After restoring, check
`qm config 207` and, if the `virtio2` line is missing, re-add it:

```bash
qm set 207 --virtio2 /dev/disk/by-id/usb-WD_Elements_25A3_575832324437304653364C39-0:0-part1,backup=0
```

### The Proxmox host

1. Reinstall Proxmox (same major version as the backup, see `info/pveversion.txt`).
2. Extract the archive somewhere else, never straight over `/`:
   `mkdir /root/restore && tar xzf pve-host_<host>_<timestamp>.tar.gz -C /root/restore`
3. Copy back only what you need: `etc/network/interfaces`, `etc/fstab`, and from `etc/pve` the
   `storage.cfg`, `user.cfg` and `qemu-server/*.conf`. Do not overwrite `/etc/pve` blindly, it is
   a cluster filesystem.
4. Reboot and compare `pvesm status` and `qm list` with `info/`.

## Caveats

- **israfel serves the NFS where its own backup is stored.** If israfel dies, Proxmox cannot read
  `Backups/` through NFS. Recover the file from the USB disk plugged into any machine, or from the
  Windows copy, put it in `/var/lib/vz/dump/` on the host and run `qmrestore` from there.
- **The host archive contains secrets** (`/etc/pve/priv`: API tokens, keys). It is created with
  mode `600`; keep it that way when it is copied elsewhere.
- **Not tested end to end on this host yet.** Two things to confirm on the first real run: that
  `/mnt/pve/nfs-storage` maps to `/mnt/storage` on israfel (the script fails with a clear message
  if `Backups/` is not there), and that the NFS export (NTFS disk) accepts the files `vzdump`
  writes as root.
- `PROXMOX_VERIFY_SSL=false` + `PROXMOX_DEV_MODE=true` are set only for the MCP while the private
  DNS/TLS is pending. They do not affect this script.

## Scheduled backups (Datacenter → Backup)

Native Proxmox jobs, visible and runnable from the GUI (*Run now*). One per VM because each job
writes to a single storage:

| Job | VM | Storage | Schedule | State |
|-----|----|---------|----------|-------|
| `backup-leliel` | 212 | `bk-leliel` | Sunday 04:00 | enabled |
| `backup-israfel` | 207 | `bk-israfel` | Sunday 04:00 | enabled |

Created with:

```bash
pvesh create /cluster/backup --id backup-leliel --schedule "sun 04:00" --storage bk-leliel \
    --vmid 212 --node server-origin --mode snapshot --compress zstd --enabled 1 \
    --notes-template "{{guestname}}" --comment "Weekly leliel (Home Assistant OS)"
```

The host archive is not a `vzdump`, so it has no job. Run `proxmox-backup.sh host` before every upgrade
(or add a cron entry in `/etc/cron.d/` on the host if you want it weekly too).

### israfel and `freeze-fs-on-backup`

israfel serves the NFS where its own backup is written. In snapshot mode `vzdump` freezes the
guest filesystems through the guest agent, and its log is written to that same NFS, so the freeze
could block the very write that precedes the thaw. To avoid it:

```bash
qm set 207 --agent enabled=1,freeze-fs-on-backup=0
```

On Proxmox 8.4.1 this is stored as a **pending** change: it only applies after israfel restarts
(check with `qm pending 207`). Restarting israfel cuts the NFS for every VM, so it is left for the
host reboot that follows the upgrade.

In practice the risk does not exist today: israfel's QEMU guest agent is **not running** (`qm
agent 207 ping` fails), and in that case `vzdump` skips the freeze by itself
(`PVE/VZDump/QemuServer.pm`, "skipping guest-agent 'fs-freeze', agent configured but not
running?"). The backup is therefore crash-consistent, which is fine for a 5 GB OS disk of an NFS
server. If the agent is ever installed and started in israfel, the setting above must be in effect
first.

## Layout decision: one storage per VM

`bk-israfel` and `bk-leliel` are separate Directory storages so the backups sit under
`Backups/<machine>/vzdump/`, like the config backups of the other VMs. Proxmox's usual setup is a
single storage with all VMs mixed in `dump/`. PBS is different again: one datastore whose real
data lives in a shared `.chunks/` folder, with the per-VM layout kept only as metadata and browsed
from its UI. Chosen on purpose; with only two hand-made VMs both options are equivalent. A new
hand-made VM needs a new `bk-<name>` storage and a new job.

## Compared with Proxmox Backup Server

| PBS feature | Here |
|-------------|------|
| Incremental backups, deduplication | No. Every `vzdump` is a full image (zstd). leliel: 1.27 GB compressed. |
| Retention, schedule, notifications, GUI | Yes: `prune-backups` per storage and native Backup Jobs. |
| Integrity verification | Manual (`zstd -t <file>`). |
| Client-side encryption | No. The destination is a private NFS disk. |
| Host backup (`proxmox-backup-client`) | Replaced by the `tar.gz` of `/etc`. Same idea, not deduplicated or incremental. |
| File-level restore | No (whole-VM restore only). |

## Log

- **2026-10-24**: `bk-israfel` and `bk-leliel` created; jobs created. leliel had 11.6 GB of
  `home-assistant.log*` (the `dirigera_platform` custom integration retrying a hub at
  `192.168.1.101:8443` every 10 s). Logs truncated and `fstrim` run inside the VM, which dropped
  the thin volume from 60% to 22%. First native backup of leliel: 1.27 GB, 28 s, `zstd -t` OK.
  Not restored yet as a test. The DIRIGERA hub problem is still open (Home Assistant task).
- **2026-10-24**: first host backup, `Backups/proxmox/pve-host_server-origin_20261024165417.tar.gz`
  (610 KB, 1595 entries). Verified: `gzip -t` OK; `storage.cfg`, `interfaces` and the `.conf` of
  VMs 207 and 212 extracted and identical to the live files; all 13 VM configs present. Note that
  `/etc/pve/qemu-server` and `/etc/pve/lxc` are symlinks, so inside the archive the VM configs are
  under `etc/pve/nodes/server-origin/qemu-server/<id>.conf`.
- **2026-10-24**: first native backup of israfel to `bk-israfel`: 855 MB, 18 s, `zstd -t` OK, NFS
  stayed readable and the VM running. `backup-israfel` re-enabled (Sunday 04:00). To do after the
  upgrade reboot: confirm `qm pending 207` is empty and test-restore both VM backups
  (`qmrestore <file> 999 --storage local-lvm`, do not start it on the LAN).
- **2026-10-24**: the host's own mount of the USB disk (`/mnt/storage`, ntfs-3g) was removed from
  the host, see [israfel-nfs.md](israfel-nfs.md). The israfel `vzdump` was also extracted and
  mounted read-only on the host to read its config, which proves the image is complete (44%
  sparse, ext4 root readable, `/etc/exports` and `fstab` present).
