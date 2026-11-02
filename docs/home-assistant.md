# Home Assistant (leliel)

Home Assistant OS (HAOS) runs in VM `leliel` (212). It is installed by hand with a Proxmox helper
script, so it is **not managed by Terraform**. Its only protection is the native `vzdump` job, see
[proxmox-backups.md](proxmox-backups.md).

## Where it runs

| Item | Value |
|------|-------|
| VM | `leliel` (212), `192.168.1.212`, 2 vCPU, 8 GB, 32 GB disk, UEFI, `onboot=1`, tag `haos` |
| Web UI | <http://192.168.1.212:8123> (also `homeassistant.local:8123`) |
| QEMU guest agent | Runs in the HAOS host, so `qm guest exec 212` reaches `docker` and the `ha` CLI (`docker exec hassio_cli ha ...`) |
| Config | `/mnt/data/supervisor/homeassistant` inside the VM (UI-configured; `configuration.yaml` is almost empty) |
| Add-ons | Advanced SSH & Web Terminal |

## Installed versions

| Component | Version |
|-----------|---------|
| Home Assistant Core | 2026.10.4 |
| Home Assistant OS | 18.3 |
| Supervisor | 2026.10.3 |
| Add-on Advanced SSH | 24.2.0 |
| HACS | 2.0.5 |
| Sonoff (custom) | v3.13.2 |

Custom components in `custom_components/`: `hacs`, `sonoff`, `dirigera_platform` (0.0.1) and
`xiaomi_airfryer` (0.0.1). Integrations set up in the UI: AEMET, PVPC hourly pricing, Sun, Met,
Shopping List, Radio Browser, Go2RTC, Google Translate, Backup, Mobile App.

## Update Core and HAOS

Update in small steps and check each one before the next. Large version jumps in one go are risky.

1. Take a fresh `vzdump` of the VM (native job, storage `bk-leliel`) before Core and again before HAOS.
2. Update Core one release step at a time. Each run makes a partial backup of the old Core:

   ```bash
   ha core update --version <v> --backup
   ```

3. After each Core step, check:
   - HTTP 200 on port 8123.
   - `ha core check` reports no error.
   - `docker logs homeassistant` shows no new errors.
4. Update HAOS one major version at a time. HAOS installs into the second slot and **waits for
   `ha host reboot`**. The other slot keeps the previous version, so a bad boot rolls back by itself.
5. After each HAOS step, check:
   - The slot is `booted/good`.
   - Core is running.
   - All 8 containers are up.
6. Update the add-ons last.

Notes:

- `home-assistant.log` is not written (Core 2025.12 and later); read errors with `docker logs homeassistant`.
- `ha addons` is deprecated; use `ha apps`.

## Roll back

- Core only: restore the partial backup `core_<version>` made by the update step
  (`ha backups restore <slug>`). Partial backups are kept in `/mnt/data/supervisor/backup`.
- Whole VM: restore the `vzdump` from `bk-leliel` (see the restore section of
  [proxmox-backups.md](proxmox-backups.md)).

## Home Assistant MCP (ha-mcp)

Claude Code talks to Home Assistant through the **ha-mcp add-on** (`ghcr.io/homeassistant-ai/ha-mcp-addon`,
8.7.0). It listens on `192.168.1.212:9583` behind a **secret path** (`/private_...`, shown in the
add-on log). It exposes about 77 tools (HACS, updates, integrations, backups, logs, apps, restart).

1. Read the secret path in the add-on log.
2. Register it in Claude Code at local scope:

   ```bash
   claude mcp add --transport http homeassistant <url>
   ```

The URL lives only in `~/.claude.json`, never in this repository. The secret path is a password: do not
paste it in chats or docs. To rotate it, regenerate it in the add-on and register it again.

Gotchas:

- Supervisor also advertises the add-on to Home Assistant's built-in MCP *client* integration, which
  shows up as a config entry `ha-mcp` (domain `mcp`, source `hassio`) in `setup_retry`. It is not needed
  and can be deleted.
- A second add-on "Home Assistant MCP Server (Dev)" is installed but stopped; remove it if unused.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| IKEA DIRIGERA: `Connection refused` on port 8443, thousands of error lines | The hub has a new IP, `192.168.1.102` (MAC `68:ec:8a:01:6d:f3`); `.101` belongs to another device. Go to *Settings → Devices & services → IKEA Dirigera Hub → gear*, enter the new IP, press the hub's action button and submit (the component re-pairs when the IP changes). The stored token stays valid. Create a DHCP reservation for that MAC in the router. If a bulb reports `isReachable: false` from the hub, check its power |
| AEMET: `API authentication error` | The key is usually valid: AEMET answers `401` intermittently and the integration retries (`setup_retry`) until it works. Test the key directly (`200` means it is valid) and wait. The UI cannot change the key (the gear only toggles radar/stations); if it fails for good, ask AEMET for a new key and re-add the integration |
| HACS: *Xiaomi Air Fryer* download fails | HACS asks for a branch named after a commit hash that does not exist. Harmless |

## Known gaps

- Home Assistant has **no backups of its own** (`no_current_backup`, no network storage). Planned: a
  network storage mount to the NAS (the Samba container on tabris, see [samba.md](samba.md)) with a user
  limited to a backup share.
- Two repairs can be dismissed in the UI: HACS reports *Platinum Weather Card* as removed from HACS, and
  the statistics of `sensor.aemet_wind_bearing` use a different mean algorithm (fixable from the repair
  item).
