# israfel: NFS server and USB disk

`israfel` (VM 207, `192.168.1.207`) is the NFS server of the homelab. It owns the 4 TB USB disk,
which is plugged into the Proxmox host and **passed through to the VM as a raw block device**.
Everything under `/mnt/storage` on the other VMs (media, photos, documents, `Backups/`) comes
from here. Created by hand with a Proxmox helper script, so it is **not** in Terraform/Packer:
this page and the `vzdump` backup are the only way to rebuild it.

```
 USB disk (WD Elements 4 TB)
   plugged in the host, USB 3 port (bus 5, port 2)
        │  /dev/sda1  (block device only, NOT mounted on the host)
        ▼
 Proxmox host server-origin ── qm: virtio2 = /dev/disk/by-id/usb-WD_Elements_...-part1
        ▼
 israfel (VM 207)  ntfs-3g mounts it on /mnt/storage ── nfs-kernel-server exports it
        ▼  NFSv4.2
 host  /mnt/pve/nfs-storage (Proxmox storage, content "images")
 VMs   /mnt/storage         (fstab: 192.168.1.207:/mnt/storage /mnt/storage nfs defaults 0 0)
```

## The disk

| Item | Value |
|------|-------|
| Enclosure | WD Elements Desktop 25A3 (`1058:25a3`) |
| Drive | WDC WD40EDAZ-11SLVB0, 4 TB |
| Serial | `WD-WX22D70FS6L9` |
| Partition table | GPT, one partition `sda1` (PARTLABEL `Elements`) |
| Filesystem | NTFS, label `Server`, UUID `58F08ACBF08AAF36` |
| Sector size | 512 logical / 4096 physical |

### Where it is plugged in

| Item | Value |
|------|-------|
| Host controller | xHCI at PCI `0000:03:00.4` |
| USB position | bus 5, port 2 (devpath `5-2`), directly on the controller's root hub, **not** through the VIA Labs hub on port 1 |
| Speed | USB 3 (5000M) |
| Physical port on the machine | _fill in: which socket on the case_ |
| Stable device paths | by serial: `/dev/disk/by-id/usb-WD_Elements_25A3_575832324437304653364C39-0:0-part1` · by port: `/dev/disk/by-path/pci-0000:03:00.4-usb-0:2:1.0-scsi-0:0:0:0-part1` |

The VM uses the **by-id** path, which follows the disk (serial number) to any USB port. The
by-path name only identifies the socket. If the disk is moved to another port, the VM keeps
working; if another disk is plugged into this socket, only a by-path reference would pick it up.

## The VM (Proxmox side)

Relevant lines of `qm config 207`:

```
scsi0:    local-lvm:vm-207-disk-1,discard=on,size=5G,ssd=1     # OS disk
efidisk0: local-lvm:vm-207-disk-0,efitype=4m,size=4M
virtio2:  /dev/disk/by-id/usb-WD_Elements_25A3_575832324437304653364C39-0:0-part1,backup=0,size=3815413M
net0:     virtio=02:62:AC:4E:7A:5F,bridge=vmbr0
ipconfig0: ip=192.168.1.207/24,gw=192.168.1.1
cores 2, memory 4096, onboot 1, tags nfs
```

- `backup=0` on `virtio2`: the 3.6 TB data disk is never part of a `vzdump`.
- The passthrough is added with
  `qm set 207 --virtio2 /dev/disk/by-id/usb-WD_Elements_25A3_575832324437304653364C39-0:0-part1,backup=0`.

### The host must NOT mount the disk

The disk is used by israfel only. The host used to have `UUID=58F08ACBF08AAF36 /mnt/storage
ntfs-3g` in `/etc/fstab`, so two NTFS drivers worked on the same volume. It was unmounted and the
line commented out on 2026-10-24 (copy of the old file: `/etc/fstab.bak-pre-upgrade`). If
`findmnt /mnt/storage` prints anything on the host, that is a regression.

## Inside israfel

Read from the `vzdump` backup of 2026-10-24 (the VM has no guest agent and was not entered).

| Item | Value |
|------|-------|
| OS | Ubuntu 24.04.2 LTS, cloud image (cloud-init) |
| Packages that matter | `nfs-kernel-server`, `nfs-common`, `ntfs-3g`, `rpcbind` |
| Not installed | `qemu-guest-agent`, Samba |
| Cron | no crontab |

`/etc/exports`:

```
/mnt/storage 192.168.1.0/24(rw,sync,no_subtree_check)
```

`/etc/fstab` (the last line is the data disk, by NTFS UUID):

```
LABEL=cloudimg-rootfs  /          ext4  discard,commit=30,errors=remount-ro  0 1
LABEL=BOOT             /boot      ext4  defaults                             0 2
LABEL=UEFI             /boot/efi  vfat  umask=0077                           0 1
UUID=58F08ACBF08AAF36  /mnt/storage  ntfs-3g  defaults,auto                  0 0
```

`/etc/netplan/50-cloud-init.yaml`: static `192.168.1.207/24` on `eth0` (matched by MAC
`02:62:ac:4e:7a:5f`), gateway `192.168.1.1`, DNS `192.168.1.200`, search domain `home`.

Things worth knowing:

- NTFS has no Unix permissions: `ntfs-3g` with `defaults` shows every file as `root` `rwxrwxrwx`.
  That is why clients that the export squashes to `nobody` (and the Proxmox host) can still write.
  Permissions are not enforced on this share.
- The export is open read-write to the whole `192.168.1.0/24`, with no authentication.
- No Samba here: the Windows `Z:` drive comes from somewhere else.
- No guest agent means Proxmox cannot freeze israfel's filesystem during `vzdump`; it skips the
  freeze and takes a crash-consistent snapshot (see [proxmox-backups.md](proxmox-backups.md)).

## Rebuild

1. **From the backup (preferred)**: restore `Backups/israfel/vzdump/vzdump-qemu-207-*.vma.zst`
   (GUI: `bk-israfel` → Backups → *Restore*, or `qmrestore <file> 207 --storage local-lvm`).
   Then check `qm config 207`: the `virtio2` line must be there; if not, re-add it with the
   `qm set` above. Make sure the USB disk is plugged in and the host does not mount it.
2. **From scratch**: create an Ubuntu 24.04 cloud-image VM with the net config above, add the
   `virtio2` passthrough, then inside:
   ```bash
   apt install -y nfs-kernel-server ntfs-3g
   echo 'UUID=58F08ACBF08AAF36 /mnt/storage ntfs-3g defaults,auto 0 0' >> /etc/fstab
   echo '/mnt/storage 192.168.1.0/24(rw,sync,no_subtree_check)' >> /etc/exports
   mkdir -p /mnt/storage && mount -a && exportfs -ra && systemctl enable --now nfs-server
   ```
3. **Check**: from the host `showmount -e 192.168.1.207` and `pvesm status` (`nfs-storage` must
   be `active`); from a VM `ls /mnt/storage`.

## Boot order

When the host reboots, israfel has to be up before the VMs mount `/mnt/storage` and before
`nfs-storage` is usable. Set on 2026-10-24:

```bash
qm set 207 --startup order=1,up=60
```

Proxmox starts VMs with an explicit order first and waits 60 s after israfel before the rest
(the other VMs have no `startup` and come afterwards). On shutdown the order is reversed, so
israfel stops last.
