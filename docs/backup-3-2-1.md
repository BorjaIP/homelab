# 3-2-1 Backup

Backup of the NAS folders that matter (the photo library and the Nextcloud documents), following
the **3-2-1 rule**: 3 copies, on 2 different media types, with 1 copy offsite. One script,
`scripts/sync-backup.ps1`, handles every source and asks which one to back up on each run.

The script always copies to a local disk. The offsite cloud copy (Box, through rclone) runs only
when `$SyncToBox = $true` in the script; its default is `$false`.

## Sources

| Name | NFS path (`Z:\...` on Windows via SMB) | Local disk copy | Box copy (when `$SyncToBox` is `$true`) |
|------|------------------------------------------|------------------|----------|
| Photos | `/mnt/storage/Photos/library/admin/` (`Z:\Photos\library\admin`) | `D:\Photos` | `box:Photos` |
| Documents | `/mnt/storage/Documents/borja/files/` (`Z:\Documents\borja\files`) | `D:\Documents` | `box:Documents` |

The destinations end up **without** the intermediate `admin/` / `borja/files/` folder: the script
copies the *contents* of that folder, so year folders sit at the root (`Photos/2015/...`, not
`Photos/admin/2015/...`).

## Scheme

| # | Copy | Medium | Location | Role |
|---|------|--------|----------|------|
| 1 | Primary | NFS (external hard drive) | `/mnt/storage/<Photos\|Documents>/...` (mounted as `Z:\...` on Windows via SMB) | Source of truth. Read directly by Immich / Nextcloud. |
| 2 | Local | Local disk on the Windows machine | `D:\Photos\` / `D:\Documents\` | Fast local backup, independent of network and third parties. Always runs. |
| 3 | Offsite | Cloud (Box) | `box:Photos` / `box:Documents` | Protects against local hardware failure, theft or fire. Runs only when `$SyncToBox = $true`. |

```
              ┌─────────────────────────────┐        ┌─────────────────────────────┐
              │  NFS: /mnt/storage/Photos   │        │ NFS: /mnt/storage/Documents │
              │  library/admin/<year>/...   │        │      borja/files/...        │
              │  (Z:\Photos\... on Windows) │        │ (Z:\Documents\... on Win.)  │
              └───────────────┬─────────────┘        └───────────────┬─────────────┘
                              │                                      │
                Immich reads  │  rclone (sync-backup.ps1)   Nextcloud│  reads
                directly      │  - pick mode and source     directly │
                              ▼                                      ▼
                    ┌─────────┴─────────┐                  ┌─────────┴─────────┐
                    ▼                   ▼                  ▼                   ▼
              D:\Photos\...      box:Photos\...      D:\Documents\...   box:Documents\...
              (copy 2)           (copy 3, optional)   (copy 2)           (copy 3, optional)
```

## Prerequisites

- The `Z:\` drive (SMB mount of the NAS, backing `/mnt/storage`) is connected. If it is not, the
  script stops with an explicit error before copying anything.
- rclone is installed on the Windows machine (step 1).
- For the Box copy only: a `box` rclone remote (step 2).

## Setup

### 1. Install rclone (Windows)

```powershell
winget install Rclone.Rclone
```

Close and reopen PowerShell so the `PATH` reloads, then verify:

```powershell
rclone version
```

If `rclone` is not recognized, find it and add it to the user `PATH`:

```powershell
Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "rclone.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object FullName
```

```powershell
$rclonePath = (Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "rclone.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).DirectoryName
[Environment]::SetEnvironmentVariable("Path", "$([Environment]::GetEnvironmentVariable('Path','User'));$rclonePath", "User")
```

Close and reopen the terminal, then retry `rclone version`.

### 2. Configure the Box remote (only for the Box copy)

rclone talks to the Box API directly and ships with its own OAuth credentials, so no custom Box app
or key is needed. Run this on the Windows machine itself, in a local PowerShell window: the
browser login only works where a browser is available.

The interactive `rclone config` wizard can auto-fill the blank `access_token` prompt and skip the
browser step. Create the remote in two explicit steps instead.

1. Run the OAuth authorization:

   ```powershell
   rclone authorize "box"
   ```

   The browser opens for the Box login. When done, rclone prints a JSON block:

   ```
   Paste the following into your remote machine --->
   {"access_token":"...","token_type":"bearer","refresh_token":"...","expiry":"..."}
   <---End paste
   ```

2. Create the remote with that token:

   ```powershell
   rclone config create box box box_sub_type=1 token='PASTE_THE_FULL_JSON_HERE'
   ```

3. Verify:

   ```powershell
   rclone lsd box:
   ```

   It lists the root folders of the Box account.

### 3. Install the script

Location: `D:\Scripts\sync-backup.ps1` (the repo copy is `scripts/sync-backup.ps1`). Logs go to
`D:\Scripts\logs\`, created on the first run.

## Run

```powershell
D:\Scripts\sync-backup.ps1
```

The script runs on demand; no scheduled task is set up.

On each run it asks two things, in this order.

**1. Mode:**

```
=== Select sync mode ===
  1) Copy  - safe, never deletes anything at the destination (default for regular runs)
  2) Sync  - mirrors the source exactly, DELETES destination files/folders
             that no longer exist at the source (use after reorganizing files)

Enter 1 or 2
```

**2. Source:**

```
=== Select what to back up ===
  1) Photos     (Z:\Photos\library\admin)
  2) Documents  (Z:\Documents\borja\files)

Enter a number
```

Any other input aborts with `Invalid option. Aborting.`

### Copy vs Sync

| Mode | Behaviour | Use it when |
|------|-----------|-------------|
| Copy (`rclone copy`) | Never deletes at the destination. A file deleted or renamed at the source stays at the destination. | Routine runs (new files added, nothing reorganized). |
| Sync (`rclone sync`) | Makes the destination match the source exactly, **including deleting** what no longer exists at the source. | Right after reorganizing the source, for example renaming or merging albums in Immich. The Storage Template renames the physical folders on the NFS, and a plain Copy would leave the old folders as orphaned duplicates. |

Use Copy for the next routine run after a Sync.

Sync is previewed first:

1. The script runs `rclone sync ... --dry-run -v` for the local disk (and for Box when
   `$SyncToBox` is `$true`).
2. It prints `Review the 'Deleted' lines above carefully. Type YES to proceed, anything else
   aborts`.
3. Review the `Deleted` lines: that is exactly what is removed from the destinations.
4. Type `YES` to proceed. Any other input prints `Aborted. No changes made.`

### What the script does

1. Shows the mode menu, then the source menu.
2. Checks that the source path is reachable. If not, it prints an error asking whether `Z:\` is
   mounted and exits.
3. In Sync mode, runs the preview and asks for `YES`.
4. If `$SyncToBox` is `$true`, runs the chosen mode from the source to the Box destination (see
   "Box copy").
5. Always runs the chosen mode from the source to the local destination (`D:\Photos` or
   `D:\Documents`), creating the folder if needed. A non-zero rclone exit code is reported with the
   log path, and the script exits with that code.
6. Writes one timestamped log per leg.

### Logs

Each run writes to `D:\Scripts\logs\`:

- `sync-local-<Name>_<timestamp>.log`
- `sync-box-<Name>_<timestamp>.log` (only when `$SyncToBox` is `$true`)

Check them when the script reports a non-zero exit code.

## Box copy

Settings at the top of the script:

| Variable | Value | Meaning |
|----------|-------|---------|
| `$SyncToBox` | `$false` | `$true` enables the Box leg. When `$false`, no connection to Box is made, no `box:` remote is required, and `not-in-box-<Name>.txt` is not regenerated. The local leg runs either way. |
| `$BoxMaxTransfer` | `25G` | Cap per run. |
| `$BoxMaxFileSize` | `250M` | Box Personal/Free plan per-file limit. |

To enable the Box copy, complete step 2 of Setup and set `$SyncToBox = $true`. To point the cloud
leg at another rclone remote, change the `BoxDest` entries in `$Sources`.

### Transfer cap

The Box upload runs with `--max-transfer $BoxMaxTransfer` so it stops cleanly instead of failing
with a "not enough space" error when the account has little free space.

- Files are copied in alphabetical order (`--order-by name`), so the oldest years upload first.
- When the cap is reached, rclone exits with code `7`. The script prints that this is expected, not
  a failure.
- The local leg is not capped.

Workflow when Box space is limited:

1. Check free space: `rclone about box:`
2. Set `$BoxMaxTransfer` below the free space, with a couple of GB of margin.
3. Run the script. It uploads as much as fits, then stops.
4. Free space in Box.
5. Re-run. Already uploaded files are skipped, so it resumes where it stopped.
6. Repeat until everything is uploaded, then raise `$BoxMaxTransfer`.

### Per-file limit

The Box Personal/Free plan rejects any file larger than 250 MB with:

```
Failed to copy: pre-upload check: Error "file_size_limit_exceeded" (403):
File size exceeds the folder owner's file size limit
```

The script passes `--max-size $BoxMaxFileSize` so rclone skips those files and logs them. They stay
on the NFS and are copied to the local disk. A plan with a higher per-file limit (Box Business)
removes the restriction.

### Files not on Box

When the Box leg runs for a source with `TrackBoxLimits = $true` (Photos), the script scans the
source for files over 250 MB and writes their full paths to:

```
D:\Scripts\logs\not-in-box-Photos.txt
```

The file is rewritten on every run. It lists only files that never fit the plan limit, not files
pending because of the transfer cap.

## Add a source

Add one entry to the `$Sources` table at the top of the script. The menu is built from the table.

| Field | Meaning |
|-------|---------|
| `Name` | Label shown in the menu, used in log names. |
| `Source` | Path on the `Z:\` mount (read-only for the script). |
| `LocalDest` | Local disk destination (always synced). |
| `BoxDest` | Box destination (synced only when `$SyncToBox` is `$true`). |
| `TrackBoxLimits` | Whether to refresh `not-in-box-<Name>.txt` (files over 250 MB). |

## Why the source is `Z:\`

The source is the SMB-mapped `Z:\` drive, not an rclone SFTP remote:

- **Performance**: on a LAN, SMB is generally faster than SFTP for bulk transfers (SMB3 supports
  multichannel and larger buffers; SFTP adds per-packet encryption overhead).
- **Access**: an SFTP remote to `192.168.1.217` chroots the user to its home directory, so it cannot
  see `Photos/library/admin` without reconfiguring the SFTP server.
