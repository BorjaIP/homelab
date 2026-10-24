# Jellyfin

Media server for movies and series. Checked against the running server on 2026-10-25.

## Where it runs

| Item | Value |
|------|-------|
| VM | `sachiel` (203), `192.168.1.203` |
| Container | `lscr.io/linuxserver/jellyfin:12.2ubu2604-ls54` (Jellyfin 12.2.0) |
| Defined in | [`terraform/docker/sachiel/docker-compose.yaml`](../terraform/docker/sachiel/docker-compose.yaml) |
| Web UI | <http://192.168.1.203:8096> (the container uses `network_mode: host`, so `docker ps` shows no ports) |
| Hostname via Traefik | none yet (`plex.home` exists, `jellyfin.home` does not) |
| Libraries inside the container | `/data/movies` = `${STORAGE}/Media/Movies`, `/data/tvshows` = `${STORAGE}/Media/Series` (NFS) |
| Config | `~/config/jellyfin` on the VM (`/config` in the container) |

The config folder is part of the weekly `~/config` backup of sachiel, see
[vm-config-backups.md](vm-config-backups.md).

## Theme: ElegantFin

Theme: **[ElegantFin](https://github.com/lscambo13/ElegantFin)** by lscambo13.

It is applied as the server's custom CSS, with this single line:

```css
@import url("https://cdn.jsdelivr.net/gh/lscambo13/ElegantFin@main/Theme/ElegantFin-jellyfin-theme-build-latest-minified.css");
```

- Stored in `~/config/jellyfin/branding.xml` and served by Jellyfin at `/Branding/Css`
  (`curl http://192.168.1.203:8096/Branding/Css` prints the line above).
- It follows `@main` and the `latest` build of the theme, so upstream changes show up by
  themselves. To freeze the look, replace `@main` with a release tag or a commit hash.
- The stylesheet is loaded by each viewer's browser from `cdn.jsdelivr.net`, so a device without
  internet access gets the default look.
- To remove the theme, empty the custom CSS field in the Jellyfin admin dashboard.

## Plugins

Installed from the Jellyfin plugin catalog, all **Active**:

| Plugin | Installed version | Config file | What it does |
|--------|-------------------|-------------|--------------|
| **Intro Skipper** | 12.0.6.0 | `IntroSkipper.xml` | Detects intros and credits and offers a "skip" button |
| **Open Subtitles** | 25.0.0.0 | `Jellyfin.Plugin.OpenSubtitles.xml` | Downloads subtitles from OpenSubtitles |
| **Trakt** | 33.0.0.0 | `Trakt.xml` | Syncs watched state, ratings and collection with Trakt |

- Plugin files: `~/config/jellyfin/data/plugins/<name>_<version>/`.
  Their settings: `~/config/jellyfin/data/plugins/configurations/`.
- The same `configurations/` folder also holds the files of the built-in TMDb, OMDb, MusicBrainz
  and Studio Images metadata providers.
- Trakt replaces what `plextraktsync` did for Plex. Plex and `plextraktsync` are commented out in
  the compose file but their containers still run on sachiel as orphans.

### Credentials stored in the config folder

The plugin settings files contain secrets (checked by field name, values not read):

- `Trakt.xml`: access token and refresh token of the linked Trakt account.
- `Jellyfin.Plugin.OpenSubtitles.xml`: OpenSubtitles username and password.

So `~/config/jellyfin` is sensitive, and so are the backups of it: the copy in
`Backups/sachiel/config/` and its dated zips on the NFS, and whatever the Windows 3-2-1 process
copies from there. Do not publish them.

## Rebuilding

- **With a backup** (the normal case): after Terraform recreates sachiel, `setup.sh` restores
  `~/config` from `Backups/sachiel/config/` while the folder is empty. The theme, the three
  plugins and their settings come back with it; nothing to redo.
- **Without a backup**: start the container, install Intro Skipper, Open Subtitles and Trakt from
  the plugin catalog, link the Trakt account again, enter the OpenSubtitles account, paste the CSS
  line above in the custom CSS field, and add the two libraries (`/data/movies`, `/data/tvshows`).
