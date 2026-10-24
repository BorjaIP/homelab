# Proxmox VE upgrade (8.4 → 9)

In-place upgrade of the single node `server-origin` (`192.168.1.111`) done over SSH, following the
official guide <https://pve.proxmox.com/wiki/Upgrade_from_8_to_9>. SSH access is documented in
[proxmox-ssh-access.md](proxmox-ssh-access.md); what is backed up before touching anything is in
[proxmox-backups.md](proxmox-backups.md).

## Before you start (checklist)

- [x] Backups exist and `Backups/` is copied off the NFS disk by the Windows process:
      `Backups/israfel/vzdump/`, `Backups/leliel/vzdump/`, `Backups/proxmox/` (host `/etc`).
      The other VMs are rebuilt with Packer + Terraform and get `~/config/` back from NFS.
- [x] `tmux` installed on the host (the guide requires a multiplexer when working over SSH).
- [x] Free space on `/`: 82 GB (the guide asks for 5 GB, ideally 10 GB).
- [x] The host no longer mounts the USB disk (see [israfel-nfs.md](israfel-nfs.md)).
- [x] israfel starts first: `qm set 207 --startup order=1,up=60`.
- [ ] Restore tests of the israfel and leliel backups: postponed until after the upgrade reboot.
- Not available: IPMI/console. The guide recommends it; the work is done in `tmux` so a dropped
  SSH session does not interrupt `apt`. Keep a monitor and keyboard within reach of the machine.
- Not needed: the Proxmox ISO is not at hand; the rollback would be a reinstall plus the `/etc`
  archive.

## Step 1: latest 8.4 (done 2026-10-24)

`pve8to9` is not shipped with 8.4.1; it arrives with a later 8.4.x. So first:

```bash
apt-get update
apt-get -s dist-upgrade     # simulation: 0 packages removed, 238 installed or upgraded
tmux new-session -d -s upgrade /root/upgrade-8.4.sh   # apt dist-upgrade, log in /root/upgrade-8.4.log
```

Result: `pve-manager` 8.4.1 → **8.4.21**, `qemu-server` 8.4.10, `pve-qemu-kvm` 9.2.0-8, kernel
`6.8.12-43-pve` installed and present in `grub.cfg`, `apt` exit code 0. No reboot yet, so the
host still runs kernel `6.8.12-10-pve` and the VMs still run the old QEMU until the restart.
All 12 VMs stayed running, all storages `active`, PVE services `active`.

The upgrade printed `Removing subscription nag from UI...`: there is an apt hook on the host (from
a community helper script) that patches the web UI after each update.

## Step 2: checker (`pve8to9 --full`, 2026-10-24)

45 checks: 35 passed, 6 skipped, 1 warning, 1 failure.

| Result | Meaning | Action |
|--------|---------|--------|
| FAIL `systemd-boot` meta-package installed | It causes problems when boot packages are upgraded. The host boots with **GRUB** (ESP has `EFI/BOOT` and `EFI/proxmox` only, no `proxmox-boot-uuids`), so systemd-boot is not in use. | `apt remove systemd-boot` (a simulation removes only that package) |
| WARN 12 running guests | Single node, they cannot be migrated. | They are shut down by the reboot, in reverse of the startup order |
| NOTICE LVM autoactivation | Only matters on shared LVM; optional on local. | Optional: `/usr/share/pve-manager/migrations/pve-lvm-disable-autoactivation` |

Everything else passes: no custom roles, `sysctl.conf` has no settings, microcode installed,
thin pool fine, no Ceph, no containers, no NVIDIA vGPU, certificates fine.

## Step 3: the jump to 9 (packages installed 2026-10-24, reboot pending)

Always inside `tmux`, with the checker clean first (`pve8to9 --full`). Commands below are the ones
actually used, in order. `/root/upgrade-9.sh` wraps the `dist-upgrade` (log: `/root/upgrade-9.log`)
and also runs `systemctl disable --now systemd-journald-audit.socket`, as the guide advises, to
avoid an audit log flood during the upgrade. A copy of `/etc/apt` from before the change is in
`/root/apt-backup-8.4` on the host.

```bash
apt remove systemd-boot                               # checker FAIL
sed -i 's/bookworm/trixie/g' /etc/apt/sources.list    # Debian repos
```

Proxmox repos (the host uses the no-subscription one, in `pve-install-repo.list`): remove that
file's line and create `/etc/apt/sources.list.d/proxmox.sources`:

```
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

The commented lines in `pve-enterprise.list`, `ceph.list` and `pvetest-for-beta.list` stay
commented (or are deleted); no Ceph is used. Then:

```bash
apt update && apt policy | grep -i trixie             # repos must resolve
apt install grub-efi-amd64                            # the host is UEFI + GRUB on LVM
apt dist-upgrade                                      # in tmux, answer the conffile prompts
pve8to9 --full                                        # again, then reboot
```

Config file prompts during `dist-upgrade` (from the guide): keep your version of `/etc/issue` and
`/etc/default/grub`; the maintainer's version is fine for `/etc/lvm/lvm.conf`,
`/etc/ssh/sshd_config` and `/etc/chrony/chrony.conf` if they were never customised.

### Result of the `dist-upgrade` (before the reboot)

- Simulation first: 843 packages installed or upgraded, 61 removed. All 61 removals were old
  library packages (`libssl3`, `libcurl4`, `libglib2.0-0`, `python3-distutils`... replaced by their
  Debian 13 versions); no Proxmox package and no service. Nothing held back.
- Installed: `proxmox-ve` 9.2.0, `pve-manager` 9.2.21, `qemu-server` 9.2.11, `pve-qemu-kvm`
  11.0.3-4, `systemd` 257, `lvm2` 2.03.31, `grub-efi-amd64` 2.12-9+pmx2, kernel
  `proxmox-kernel-7.0` (7.0.14-25-pve). `apt` exit code 0.
- Verified before rebooting: GRUB (shim + grub 2.12) rewritten on the ESP at 19:51, EFI boot entry
  `proxmox` -> `\EFI\proxmox\shimx64.efi`, `grub.cfg` lists the new kernel, all 12 VMs still
  running, all storages `active`, `apt-get check` and `dpkg --audit` clean.
- `pve8to9 --full` afterwards: 44 checks, 0 failures, 2 warnings: the new kernel is installed but
  not booted (expected), and no NTP daemon (see below).

### Issues found, and what was left as it is

| Issue | Cause / decision |
|-------|------------------|
| `chrony` fails to start: `Could not send notification to $NOTIFY_SOCKET` | `chrony` 4.8 (Proxmox repo) with the old 6.8 kernel still running on a Debian 13 userspace. Not blocking. To check after the reboot; if it persists, try without the seccomp filter (`-F 0` in `/etc/default/chrony`) or use `systemd-timesyncd`. |
| `postfix` restart failed in a post-install trigger (`conflicting jobs 'restart' and 'stop'`) | `postfix` is active afterwards. Harmless. |
| `user@0.service` (root's user manager) fails on SSH logins | Side effect of upgrading systemd while it runs; the sessions work. Expected to disappear after the reboot. |
| `glances.service` fails after the upgrade | Python virtualenv built on Python 3.11, now 3.13. Fixed, see [glances-host.md](glances-host.md). |
| `/etc/lvm/lvm.conf.dpkg-dist`, `/etc/issue.dpkg-dist`, `/etc/ca-certificates.conf.dpkg-old` | `--force-confold` kept the local files. `lvm.conf` holds Proxmox's `global_filter` for ZFS/Ceph volumes, so it was not replaced. Compare later with `diff` and delete the leftovers. |
| Network interface name | The bridge uses `enp2s0f1` (PCI-path name, normally stable). If the host has no network after the reboot, use the console: `ip -br link`, fix `bridge-ports` in `/etc/network/interfaces`, `ifreload -a`. |

### Pre-reboot health check of every VM (2026-10-24)

Read-only, through the guest agent (11 of 12 VMs; israfel has none):

- Docker enabled and active in the 10 Docker VMs; every container running; every compose service
  has `restart: always`. Home Assistant OS containers show restart policy `no` because its
  Supervisor starts them.
- Existing problems unrelated to the reboot: sachiel `plextraktsync` restarting in a loop and
  `plex` unhealthy; matarael `homepage` unhealthy; shamshel root disk at 84%; matarael and
  sahaquiel with about 430-460 MB of free RAM.
- Weekly `~/config/` backups ran on all VMs on the previous Sunday.
- Boot-order finding: Docker did not wait for the NFS mount in any VM. Fixed for the 5 stacks that
  use the NFS, see "Docker waits for the NFS mount" in [vm-config-backups.md](vm-config-backups.md).
- USB disk timing at the last host boot (kernel 6.8): the disk appeared 8 s before the first VM
  was started. israfel is now the first VM (`order=1,up=60`), the host no longer mounts the disk.
  Not measured with kernel 7.0.

### Reboot result (2026-10-24, 20:16)

- Host back in about 2.5 minutes: `pve-manager` 9.2.21, kernel `7.0.14-25-pve`, network
  (`enp2s0f1` in `vmbr0`) and the USB disk detected; the host does **not** mount the disk.
- Start sequence as configured: israfel at 20:18:47, a 60 s wait, then the other 11 VMs, 3 s apart.
  All 12 running; the 5 storages `active`; `showmount -e 192.168.1.207` lists the export.
- Inside the VMs (after about one minute): every Docker VM has Docker active and every container
  running, with the same counts as before the reboot (1, 4, 6, 2, 2, 4, 2, 2, 7, 5 and the 8 of
  Home Assistant). In sachiel, ireul and tabris Docker started 20 s **after** `mnt-storage.mount`
  and the containers see the real data.
- `chrony` is active again (the failure was the old kernel on the new userspace).
- `qm pending 207` is empty: `freeze-fs-on-backup=0` is now in effect for israfel.
- `glances.service` on the host failed after the reboot: its virtualenv was built on Debian 12 with
  Python 3.11 and the upgrade replaced Python with 3.13 (`No module named glances`). Rebuilt the
  same day with `scripts/proxmox-glances-setup.sh`; see [glances-host.md](glances-host.md). The host went
  from `degraded` to `running`.

## After the reboot

1. Clear the browser cache and force-reload the UI.
2. Check `pveversion` (9.x), `qm list` (all 12 running), `pvesm status`, `showmount -e 192.168.1.207`.
   israfel must come first (startup order), the others mount its NFS afterwards.
3. The kernel changes from 6.8 to 6.14: `qm pending 207` empty, PCI/USB passthrough n/a.
4. Test-restore the `vzdump` backups of israfel and leliel (`qmrestore <file> 999 --storage
   local-lvm`, not started on the LAN) and delete VM 999.
5. Optional: `apt modernize-sources`; remove `/etc/fstab.bak-pre-upgrade` when happy.
6. Outside Proxmox: the Terraform provider (`Telmate/proxmox`) and the Proxmox MCP talk to the
   API; check that `terraform plan` and the MCP still work against 9.x.

## Rollback

There is no downgrade from 9 to 8. If the host does not boot: boot another kernel from GRUB; if it
is unrecoverable, reinstall Proxmox 8.4, restore from the `Backups/proxmox/` archive
(`/etc/pve` VM configs, `storage.cfg`, network) and re-attach the VM disks, which live on
`local-lvm` and are not touched by a reinstall unless that volume is formatted.
