# Lilith (Hermes assistant)

Lilith is the personal assistant. It runs Hermes Agent (Nous Research) on its own VM and talks to the
owner through Telegram. No secret values are recorded here.

## Overview

| Item | Value |
|------|-------|
| VM | `lilith`, Proxmox VM 202, 192.168.1.202 |
| OS | Ubuntu 24.04.2 LTS, kernel 6.8.0-147 |
| Resources | 4096 MB RAM (about 780 MB used), disk 30 GB (52% used) |
| Terraform | Creates the VM only (`provision = false` in `terraform.tfvars`); no `docker/lilith/` folder |
| Installed by | Hand, as user `bis` (uid 1001) |
| Network exposure | SSH (22) and the Hermes dashboard on `192.168.1.202:9119` (LAN only, password; see [Dashboard](#dashboard-for-the-hermes-app)). Telegram works by outbound polling |

## Hermes installation

| Item | Value |
|------|-------|
| Version | Hermes Agent v0.21.4 (2026.9.21), commit `16fe260`, install method `git` |
| Code | `~/.hermes/hermes-agent/` (own venv) |
| Home | `~/.hermes/` |
| Service | User unit `~/.config/systemd/user/hermes-gateway.service`, enabled, running since boot |
| Boot | `Linger=yes` for `bis`, so the gateway starts without a login |
| Process | `~/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run` (about 350 MB) |
| Channel | Telegram only, polling mode, state `connected` |
| Model | `gpt-5.6-luna` through the OpenAI API (`provider: openai-api`) |
| Terminal backend | `local` (commands run directly on the VM as `bis`) |

`hermes` is not on the PATH of a non-interactive SSH shell; use the venv python above or an
interactive login.

### Files and folders

| Path | Purpose |
|------|---------|
| `~/.hermes/SOUL.md` | Identity: name **Lilith** |
| `~/.hermes/config.yaml` | Settings (model, memory, compression, per-platform toolsets, dashboard) |
| `~/.hermes/.env` | Secrets. Keys present: Telegram bot token and allowed users, OpenAI key, Tavily key, gateway token, terminal and browser tuning |
| `~/.hermes/auth.json` | OAuth credentials |
| `~/.hermes/memories/MEMORY.md`, `USER.md` | Agent memory. `MEMORY.md` has 4 entries (preferences, CoreFit setup, Spanish, projects file). `USER.md` is the empty template |
| `~/.hermes/projects.json` | Project registry used as source of truth by the agent |
| `~/.hermes/skills/` | 16 groups, including `corefit-bookings`, `authenticated-booking-automation`, `reservation-automation`, `openclaw-imports/tavily-search` |
| `~/.hermes/state.db`, `sessions/`, `kanban.db` | Sessions, state and kanban (SQLite) |
| `~/.hermes/cron/` | Scheduler. No jobs defined |
| `~/.hermes/migration/openclaw/20260923T210911/` | Archived import report, notes and config |
| `~/pkm` | Clone of the public `BorjaIP/pkm` repo and Hermes' working directory (`terminal.cwd`). The vault folder `~/pkm/pkm` is replicated two-way by Syncthing. Nothing on lilith commits to git. See [pkm-unification.md](pkm-unification.md) |
| `~/.local/bin/syncthing` | Syncthing 2.1.7 for user `bis`, user service `syncthing.service` (pinned, no self-upgrade, no default folder, GUI on 127.0.0.1:8384 only). One folder, `pkm-vault`, at `/home/bis/pkm/pkm`, shared with israfel. Ignored: `.obsidian`. Git ignores its markers through `~/pkm/.git/info/exclude`. Installed with `scripts/lilith/install-syncthing.sh`, paired with `scripts/syncthing/pair-pkm.sh`. See [syncthing-israfel.md](syncthing-israfel.md) |
| `~/icloud-bridge` | Apple Reminders CLI for Hermes (project `~/projects/icloud-bridge` on the PC, deployed with `deploy/deploy.sh`). `uv` 0.9.16 in `~/.local/bin`, dependencies synced, 161 tests pass there, `.env` created (mode 600). Not logged in: `ICLOUD_APPLE_ID` is empty and `status` says so |
| `~/.ssh/pkm_deploy` | Deploy key for the `pkm` repo, with write access on GitHub; used through the `github-pkm` alias in `~/.ssh/config` |

### Toolsets

`platform_toolsets` in `config.yaml` maps each platform to one bundle (`hermes-telegram`, `hermes-cli`,
and so on). Extras: web search through Tavily, local speech-to-text (`whisper` base model, language
`en`), persistent memory and skills.

The gateway logs a warning at start: platforms `teams` and `google_chat` point to toolsets that do not
exist (`hermes-teams`, `hermes-google_chat`, upstream issue #38798). They are not in use, so it is
noise.

## Dashboard for the Hermes app

The Hermex iPhone app connects to the Hermes **dashboard**, not to the API server.

- Service: user unit `~/.config/systemd/user/hermes-dashboard.service`, enabled, runs
  `hermes dashboard --host 192.168.1.202 --no-open --skip-build`. Plain HTTP on the LAN address only.
- `config.yaml` has a `dashboard:` block: `public_url: http://192.168.1.202:9119` and `basic_auth`
  (username `borja`, only the password hash). A copy of the file without the block is
  `config.yaml.pre-dashboard`.
- The generated password is in `~/.hermes/dashboard-login.txt` (mode 600). Read it, put it in a password
  manager and delete the file.
- The dashboard refuses to bind to the network without an auth provider, so it cannot start unprotected.
- The password crosses the LAN unencrypted. Remote access goes through the Tailscale container on
  sandalphon (`terraform/docker/sandalphon/docker-compose.yaml`, advertises `192.168.1.0/24`): with
  Tailscale on, the app uses `http://192.168.1.202:9119`.
- The dashboard manages config, API keys and sessions, so treat the password like the keys it can reach.
- Disable: `systemctl --user disable --now hermes-dashboard.service` and remove the `dashboard:` block.

## Operations

```bash
ssh -i ~/.ssh/homelab_proxmox bis@192.168.1.202
systemctl --user status hermes-gateway.service
journalctl --user -u hermes-gateway.service -f
systemctl --user restart hermes-gateway.service
```

Changing CPU or RAM from Terraform reboots the VM; Hermes comes back by itself.

## Backup

A weekly `vzdump` (`bk-lilith`, job `backup-lilith`, Sunday 04:30) covers the VM, see
[proxmox-backups.md](proxmox-backups.md). `~/.hermes` is covered, but a restore is whole-VM only.
Hermes' own `pre_update_backup` is off.

## Known gaps

1. **No scheduled jobs.** `~/.hermes/cron/` is empty; create jobs with `hermes cron`.
2. **`corefit-booker` status is unverified.** `projects.json` says the container was stopped and
   removed on 2026-10-08, but its status field still says `ejecutando`. `bis` cannot read the Docker
   socket, so check with `sudo docker ps -a` on lilith.
3. **`USER.md` is empty**, so the agent has no profile of the owner beyond `MEMORY.md`.
4. **Speech-to-text language is `en`** while the owner writes in Spanish.
5. Planned, not started: Chollometro price monitor with Telegram alerts.
