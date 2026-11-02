# Seerr

Media request manager, connected to **Jellyfin**, Radarr and Sonarr.

## Where it runs

| Item | Value |
|------|-------|
| VM | `shamshel` (204), `192.168.1.204` |
| Container | `ghcr.io/seerr-team/seerr:v3.5.1`, `network_mode: host`, port 5055 |
| Defined in | [`terraform/docker/shamshel/docker-compose.yaml`](../terraform/docker/shamshel/docker-compose.yaml) |
| URL | <http://seerr.home> (Traefik on gaghiel) or <http://192.168.1.204:5055> |
| Config | `~/config/seerr` on the VM (`/app/config`), owned by UID 1000 (`ubuntu`): the image runs as UID 1000, not as `bis` (1001) |
| Media server | Jellyfin `192.168.1.203:8096`, libraries `Movies` and `Shows` |
| Radarr | `192.168.1.204:7878`, profile `HD-1080p`, folder `/movies`, default |
| Sonarr | `192.168.1.204:8989`, profile `HD-1080p`, folder `/tv`, default |

Notifications are not configured. The admin account is the Jellyfin user `borja`.

## Changing the media server (reset procedure)

Seerr has **no official way to switch media server** (issues
[#2522](https://github.com/seerr-team/seerr/issues/2522) and
[#2448](https://github.com/seerr-team/seerr/discussions/2448)). The maintainer's workaround is to
delete `settings.json` and run the setup wizard again. The data lives in the database and is kept.
Radarr and Sonarr settings are lost with `settings.json`, so they are saved and restored.

1. `docker stop seerr`, then `cp -a ~/config/seerr ~/config/seerr.bak-<date>` (stopped first, so
   the copy is consistent).
2. Save the `radarr` and `sonarr` arrays of `settings.json`; delete `settings.json` and
   `settings.old.json`; `docker start seerr`.
3. Open the web UI and run the wizard: choose Jellyfin, use the server **IP and port**
   (`192.168.1.203`, `8096`) rather than a hostname, and sign in with a Jellyfin admin account. Skip
   the Radarr and Sonarr step.
4. Restore the two arrays through `POST /api/v1/settings/radarr` and `/sonarr` with the Seerr API
   key (`main.apiKey` in the new `settings.json`). `POST .../test` first: it returns the profiles
   and root folders, so the saved profile id can be checked.
5. To undo, stop Seerr, replace `~/config/seerr` with the backup folder and start it.

Notes:

- The wizard converts the existing admin (user id 1) to a Jellyfin user; its requests stay under it.
- Seerr's API key changes when `settings.json` is deleted. Nothing in this repo uses it (Homepage
  only links to Seerr and monitors it).
- The saved arrays contain API keys: store them with mode 600.

## Known issues

- **Six Harry Potter films are not matched**: Jellyfin has no TMDb id for items named like
  "1 - Harry Potter y la piedra filosofal" (`Unable to find TMDb ID` in the Seerr log). Fix with
  *Identify* in Jellyfin.
- `network.trustProxy` is `false` although Seerr sits behind Traefik.
