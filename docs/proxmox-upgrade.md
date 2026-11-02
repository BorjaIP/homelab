# Proxmox VE upgrade (8.4 → 9)

Procedure for the in-place upgrade of the single node `server-origin` (`192.168.1.111`) over SSH,
following the official guide <https://pve.proxmox.com/wiki/Upgrade_from_8_to_9>. SSH access is
documented in [proxmox-ssh-access.md](proxmox-ssh-access.md); what is backed up before touching
anything is in [proxmox-backups.md](proxmox-backups.md).

The upgrade runs in three stages: update to the latest 8.4, run the checker, jump to 9. Work inside
`tmux` so a dropped SSH session does not interrupt `apt`.

## Prerequisites

- [ ] Backups exist and `Backups/` is copied off the NFS disk by the Windows process:
      `Backups/israfel/vzdump/`, `Backups/leliel/vzdump/`, `Backups/lilith/vzdump/`,
      `Backups/proxmox/` (host `/etc`). The Terraform-managed VMs are rebuilt with Packer +
      Terraform and get `~/config/` back from NFS.
- [ ] `tmux` installed on the host (the guide requires a multiplexer when working over SSH).
- [ ] Free space on `/`: at least 5 GB, ideally 10 GB (`df -h /`).
- [ ] The host does not mount the USB disk (see [israfel-nfs.md](israfel-nfs.md)).
- [ ] israfel starts first, so the other VMs find the NFS: `qm set 207 --startup order=1,up=60`.
- [ ] Restore tests of the israfel and leliel backups (see "Restore" in
      [proxmox-backups.md](proxmox-backups.md)).
- [ ] A monitor and keyboard within reach of the machine (no IPMI/console). The rollback is a
      reinstall plus the `/etc` archive, so keep the Proxmox ISO available.

## 1. Update to the latest 8.4

`pve8to9` is not shipped with 8.4.1; it arrives with a later 8.4.x, so update first:

```bash
apt-get update
apt-get -s dist-upgrade     # simulation: nothing should be removed
tmux new-session -d -s upgrade /root/upgrade-8.4.sh   # apt dist-upgrade, log in /root/upgrade-8.4.log
```

Verify:

- `apt` exit code 0 in the log.
- `pveversion` shows the new 8.4.x and the new kernel is present in `grub.cfg`.
- All VMs still running (`qm list`), all storages `active` (`pvesm status`), PVE services `active`.

The host runs the old kernel and the VMs the old QEMU until the next restart. An apt hook on the
host (from a community helper script) prints `Removing subscription nag from UI...` and patches the
web UI after each update.

## 2. Run the checker

```bash
pve8to9 --full
```

Handle each result:

| Result | Meaning | Action |
|--------|---------|--------|
| FAIL `systemd-boot` meta-package installed | It causes problems when boot packages are upgraded. The host boots with **GRUB** (ESP has `EFI/BOOT` and `EFI/proxmox` only, no `proxmox-boot-uuids`), so systemd-boot is not in use. | `apt remove systemd-boot` (a simulation removes only that package) |
| WARN running guests | Single node, they cannot be migrated. | The reboot shuts them down, in reverse of the startup order |
| NOTICE LVM autoactivation | Only matters on shared LVM; optional on local. | Optional: `/usr/share/pve-manager/migrations/pve-lvm-disable-autoactivation` |

Re-run the checker until it reports no failures.

## 3. Upgrade to 9

Always inside `tmux`, with the checker clean first (`pve8to9 --full`).

1. Save the apt configuration: `cp -a /etc/apt /root/apt-backup-8.4`.
2. Remove `systemd-boot` and point the Debian repos to trixie:

   ```bash
   apt remove systemd-boot
   sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
   ```

3. Proxmox repos. The host uses the no-subscription repository, defined in `pve-install-repo.list`:
   remove that file's line and create `/etc/apt/sources.list.d/proxmox.sources`:

   ```
   Types: deb
   URIs: http://download.proxmox.com/debian/pve
   Suites: trixie
   Components: pve-no-subscription
   Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
   ```

   Keep the lines in `pve-enterprise.list`, `ceph.list` and `pvetest-for-beta.list` commented (or
   delete them); no Ceph is used.

4. Check the repos and install the bootloader package (the host is UEFI + GRUB on LVM):

   ```bash
   apt update && apt policy | grep -i trixie             # repos must resolve
   apt install grub-efi-amd64
   ```

5. Run the upgrade. `/root/upgrade-9.sh` wraps `apt dist-upgrade` (log: `/root/upgrade-9.log`) and
   also runs `systemctl disable --now systemd-journald-audit.socket`, as the guide advises, to
   avoid an audit log flood:

   ```bash
   apt-get -s dist-upgrade                               # simulation: only old library packages removed, nothing held back
   tmux new-session -d -s upgrade /root/upgrade-9.sh    # or: apt dist-upgrade inside tmux
   ```

   Config file prompts (from the guide): keep your version of `/etc/issue` and
   `/etc/default/grub`; the maintainer's version is fine for `/etc/lvm/lvm.conf`,
   `/etc/ssh/sshd_config` and `/etc/chrony/chrony.conf` if they were never customised.
   `/etc/lvm/lvm.conf` holds Proxmox's `global_filter` for ZFS/Ceph volumes, so keep the local file
   if in doubt and compare it with `diff` later.

6. Verify before rebooting:

   ```bash
   pveversion                      # pve-manager 9.x
   pve8to9 --full                  # no failures; remaining warnings: new kernel not booted, NTP
   apt-get check && dpkg --audit   # clean
   qm list; pvesm status           # VMs running, storages active
   ```

   Also check that GRUB was rewritten on the ESP, the EFI boot entry `proxmox` points to
   `\EFI\proxmox\shimx64.efi` and `grub.cfg` lists the new kernel.

### Known side effects before the reboot

| Symptom | Cause / action |
|---------|----------------|
| `chrony` fails to start: `Could not send notification to $NOTIFY_SOCKET` | New `chrony` with the old kernel still running on the new userspace. Check after the reboot; if it persists, try without the seccomp filter (`-F 0` in `/etc/default/chrony`) or use `systemd-timesyncd`. |
| `postfix` restart fails in a post-install trigger (`conflicting jobs 'restart' and 'stop'`) | `postfix` is active afterwards. Harmless. |
| `user@0.service` (root's user manager) fails on SSH logins | Side effect of upgrading systemd while it runs; sessions work. Disappears after the reboot. |
| `glances.service` fails | The Glances virtualenv is tied to the old Python version. Rebuild it, see [glances-host.md](glances-host.md). |
| `/etc/lvm/lvm.conf.dpkg-dist`, `/etc/issue.dpkg-dist`, `/etc/ca-certificates.conf.dpkg-old` | Left by keeping the local files. Compare with `diff` and delete the leftovers. |
| Network interface name | The bridge uses `enp2s0f1` (PCI-path name, normally stable). If the host has no network after the reboot, use the console: `ip -br link`, fix `bridge-ports` in `/etc/network/interfaces`, `ifreload -a`. |

### Pre-reboot health check of the VMs

Read-only, through the guest agent (israfel has none):

- Docker is enabled and active in the Docker VMs, every container is running, and every compose
  service has `restart: always`. Home Assistant OS containers show restart policy `no` because its
  Supervisor starts them.
- Weekly `~/config/` backups ran on all VMs (see [vm-config-backups.md](vm-config-backups.md)).
- Docker waits for the NFS mount in the stacks that use it, see "Docker waits for the NFS mount" in
  [vm-config-backups.md](vm-config-backups.md).
- israfel is the first VM to start (`order=1,up=60`), so the USB disk is attached before the other
  VMs need the NFS.

## 4. Reboot and verify

1. Reboot the host. It takes a few minutes; israfel starts first, waits 60 s, then the other VMs
   start 3 s apart.
2. Clear the browser cache and force-reload the UI.
3. Check:

   ```bash
   pveversion                      # 9.x
   uname -r                        # new kernel
   qm list                         # all VMs running
   pvesm status                    # all storages active
   showmount -e 192.168.1.207      # lists the export
   qm pending 207                  # empty: freeze-fs-on-backup=0 is in effect
   systemctl is-system-running     # running
   systemctl is-active chrony      # active
   ```

4. Inside the VMs, check that Docker is active, every container is running, and Docker started
   after `mnt-storage.mount` in the stacks that use the NFS.
5. If `glances.service` failed, rebuild its virtualenv: [glances-host.md](glances-host.md).
6. Test-restore the `vzdump` backups of israfel and leliel (`qmrestore <file> 999 --storage
   local-lvm`, not started on the LAN) and delete VM 999.
7. Optional: `apt modernize-sources`; remove `/etc/fstab.bak-pre-upgrade`.
8. Outside Proxmox: the Terraform provider (`Telmate/proxmox`) and the Proxmox MCP talk to the
   API; check that `terraform plan` and the MCP still work against 9.x.

## Rollback

There is no downgrade from 9 to 8. If the host does not boot, boot another kernel from GRUB. If it
is unrecoverable, reinstall Proxmox 8.4, restore from the `Backups/proxmox/` archive (`/etc/pve` VM
configs, `storage.cfg`, network) and re-attach the VM disks, which live on `local-lvm` and are not
touched by a reinstall unless that volume is formatted.
