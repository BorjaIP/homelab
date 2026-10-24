# VM Config Backups

How each VM's Docker service configuration (`~/config/`) is backed up to NFS, and how it gets
restored automatically only for a genuinely fresh VM.

## Design goals

Three separate things, on purpose:

1. **Disaster recovery** — if Proxmox dies and a VM has to be recreated from scratch (`terraform
   apply` against an empty disk), it should come back up with its last known-good config
   automatically, without any manual step.
2. **Periodic backup** — runs on a schedule (cron, weekly) and only ever pushes `~/config/` to
   NFS. It never triggers a restore, never touches the live VM's files.
3. **Restoring onto an already-live VM** (rolling back a bad change, recovering a single
   service) is **never automatic** — always a deliberate, manual action. See below.

Goal 1 is what `setup.sh`'s "empty config dir" check implements. Goals 2 and 3 are why
`backup.sh` only ever pushes, never pulls, and why there's no code path anywhere that restores
onto a non-empty `config/` without a human explicitly running a command for it.

## Where it lives

- **NFS server**: `israfel` (192.168.1.207), NTFS disk mounted at `/mnt/storage`.
- **Backup root**: `/mnt/storage/Backups/<hostname>/config/` — one folder per VM (`ramiel`,
  `gaghiel`, `sachiel`, ...), each containing an exact copy of that VM's `~/config/` directory.
- **On each VM**: `/home/bis/config/<service>/` — one subfolder per Docker service (`transmission`,
  `traefik`, `plex`, ...), bind-mounted into the containers. This is the only thing backed up;
  media libraries (`${STORAGE}/Media`, `/Photos`, etc.) are separate and already live on NFS.

```
                    ┌─────────────────────────────────────────┐
                    │  israfel (192.168.1.207) — NFS / NTFS    │
                    │  /mnt/storage/Backups/<hostname>/config  │
                    └───────────────▲───────────────┬─────────┘
                                     │               │
                         backup.sh  │               │  setup.sh
                         (rsync push)               │  (rsync restore,
                                     │               │   only if config/ is empty)
                                     │               ▼
                    ┌────────────────┴──────────────────────────┐
                    │  VM (e.g. ramiel, 192.168.1.205)           │
                    │  /home/bis/config/<service>/...            │
                    └─────────────────────────────────────────────┘
```

## Two separate scripts, two separate directions

In the repo they are `scripts/vm-setup.sh` and `scripts/vm-backup.sh` (the `vm-` prefix keeps them
apart from the Proxmox host scripts in the same folder). Terraform copies them to each VM as
`/home/bis/setup.sh` and `/home/bis/backup.sh`, which are the names used below and in the cron job.

### `setup.sh` — restore (NFS → VM), runs on provisioning

Executed by Terraform's `null_resource.docker_compose_setup` provisioner every time a VM is
(re)provisioned. Relevant part:

```bash
mkdir -p "${CONFIG_PATH}"
if [ -d "${MOUNT_POINT}/Backups/${1}/config" ] && [ -z "$(ls -A "${CONFIG_PATH}")" ]; then
    for entry in "${MOUNT_POINT}/Backups/${1}/config"/*; do
        name=$(basename "${entry}")
        echo "  - ${name}"
        rsync -a "${entry}" "${CONFIG_PATH}/"
    done
fi
```

If a backup for that hostname exists on NFS **and** `~/config/` on the VM is empty, it restores
the last known-good config before `docker compose up -d` runs. This is what turns a freshly
rebuilt VM back into a working one instead of starting every service from an empty config.

The check is deliberately based on whether `~/config/` is empty, not on some marker file. A VM
that's already alive and populated (even one that never had a backup on NFS before, and only
just got its first one) is never touched automatically — restoring onto a live VM is something
you do by hand (`rsync` from `/mnt/storage/Backups/<hostname>/config/` yourself), never
something `terraform apply` decides to do for you.

### `backup.sh` — backup (VM → NFS), runs weekly via cron

```bash
# zip the previous backup (timestamped) if one exists, then...
for entry in "${CONFIG_PATH}"/*; do
    name=$(basename "${entry}")
    echo "  - ${name}"
    sudo rsync -a "${entry}" "${BACKUP_DIR}/"
done
# ...delete zips older than 28 days
find "${MOUNT_POINT}/Backups/$(hostname)" -maxdepth 1 -name "config_*.zip" -mtime +28 -delete
```

Each run: rotates the previous backup into a timestamped `.zip` (so you keep point-in-time
snapshots, not just the latest state), pushes the current `~/config/` to NFS folder-by-folder
(printing just the folder name — the old `--info=progress2` dumped a flood of per-file progress
lines when run non-interactively over SSH), then prunes zips older than 28 days. The `sudo` on
the `rsync` matters: some services (Postgres, pgvector) run as their own internal container UID
with `700`-permission data directories that the plain `bis` user can't read into.

## Why the restore only fires on an empty `config/`

`vm/provisioner.tf` sets:

```hcl
triggers = {
  always_run = timestamp()
}
```

This forces the `null_resource` (and therefore the whole `setup.sh` run, including the restore
step) to execute on **every single `terraform apply`** — not just the first time the VM is
created. Without a guard, every `apply` would blindly `rsync` the NFS backup on top of
`~/config/`, silently overwriting whatever is currently running.

An earlier version of this script used a one-time `.rsync_done` marker file instead of checking
whether `config/` was empty. That broke in practice: `ireul` had been live for months with real
data, but never had a backup on NFS until one was taken by hand recently. The very next
`terraform apply` saw "a backup now exists" + "no `.rsync_done` marker" and tried to restore onto
the already-running VM — `rsync` failed trying to `chmod` files inside `immich-cache/` that were
owned by a different UID (root, written by the ML container), aborting `setup.sh` under `set -e`
partway through Step 4.

The fix: drop the marker file entirely and check `[ -z "$(ls -A "${CONFIG_PATH}")" ]` instead —
i.e. only restore when `~/config/` is **actually empty**. That's a true "is this a fresh VM"
check, immune to the timing issue above, and it's what makes `terraform apply` idempotent with
respect to config: it can re-run `setup.sh` freely (redeploy `docker-compose.yaml`, re-copy
`.env`, `docker compose up -d` again) without ever touching `~/config/` on a VM that already has
one.

## Manual restore

Use this when you need to roll back a single service, or recover one after breaking it — never
automatic, always run by hand.

```bash
ssh bis@192.168.1.<X>

# Stop the service so nothing is writing to its files while you restore
sudo docker compose -f ~/docker-compose.yaml stop <service>

# Restore that service's folder from the last backup (mirrors it exactly, removing
# anything currently in there that isn't in the backup)
sudo rsync -a --delete /mnt/storage/Backups/$(hostname)/config/<service>/ ~/config/<service>/

# Bring it back up
sudo docker compose -f ~/docker-compose.yaml up -d <service>
```

Drop `--delete` if you'd rather merge the backup on top of what's there instead of mirroring it
exactly (keeps any extra files currently in `~/config/<service>/` that aren't in the backup).

To restore *everything* on a VM (not just one service) — same idea, whole `config/` instead of
one subfolder:

```bash
sudo docker compose -f ~/docker-compose.yaml down
sudo rsync -a --delete /mnt/storage/Backups/$(hostname)/config/ ~/config/
sudo docker compose -f ~/docker-compose.yaml up -d
```

## Automation: what's actually scheduled

`setup.sh` installs a weekly cron job for `backup.sh`:

```bash
CRON_JOB="0 3 * * 0 /home/${USER}/backup.sh >> /home/${USER}/backup.log 2>&1"
(crontab -l 2>/dev/null | grep -v "backup.sh" || true; echo "${CRON_JOB}") | crontab -
```

Runs every Sunday at 3am. Since it's installed by `setup.sh` itself, it gets (re-)registered on
every `terraform apply` too — idempotently (the `grep -v` strips any previous `backup.sh` line
before re-adding it, so re-running `setup.sh` doesn't duplicate the cron entry).

The `|| true` matters: without it, on a VM with **no pre-existing crontab**, `crontab -l` returns
nothing and `grep -v` finds zero matching lines to keep, which makes `grep` exit `1`. Under
`set -e`, inherited into the subshell, that aborted the subshell *before* it ever reached the
`echo` of the new cron line — so `crontab -` received empty input and silently installed nothing,
with no error anywhere. Hit this on both `gaghiel` and `ireul` (their first time ever getting a
crontab); confirmed by reproducing it locally before fixing it. Currently installed and verified
(`crontab -l`) on `ramiel`, `gaghiel` and `ireul`; the rest will pick it up on their next
`terraform apply`.

## Docker waits for the NFS mount (stacks that use it)

After a host reboot, Docker used to start containers about 17 s after boot without waiting for
the NFS share, so a container with a bind mount under `/mnt/storage` could start against the
empty local folder (empty libraries, uploads written to the VM disk). `setup.sh` now has a
"Step 5.5" that detects whether the VM's `docker-compose.yaml` references `${STORAGE}` or
`/mnt/storage` and, if so, installs a systemd drop-in:

```
/etc/systemd/system/docker.service.d/10-nfs.conf
[Unit]
RequiresMountsFor=/mnt/storage
```

Docker then starts only after `mnt-storage.mount` succeeded. It is a hard dependency on purpose:
if the NFS is down, those stacks do not start rather than start on the wrong disk. Stacks that do
not use the NFS (gaghiel/Traefik, matarael/homepage, sahaquiel/Uptime Kuma, sandalphon/VPN) do not
get it, so they keep running when israfel is down (Uptime Kuma must keep alerting).

Applied by hand on 2026-10-24 to the running VMs that use it: sachiel, shamshel, ramiel, ireul and
tabris (`daemon-reload` only; Docker and the containers were not restarted). Check with
`systemctl show docker -p RequiresMountsFor`.
