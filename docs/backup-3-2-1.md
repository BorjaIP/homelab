# 3-2-1 Backup

Backup scheme for the NAS folders that matter (currently the photo library and the Nextcloud
documents), following the **3-2-1 rule**: 3 copies, on 2 different media types, with 1 copy
offsite. One script (`sync-backup.ps1`) handles every source — it asks which one to back up on
each run (see "Select what to back up" below).

> **Status: cloud leg paused.** The cloud provider is being reconsidered (moving away from Box),
> so cloud upload is currently switched off in the script (`$SyncToBox = $false`). Only copy 1
> (NFS) and copy 2 (local disk) are active right now. See "Pausing/resuming the cloud copy" below.

## Sources

| Name | NFS path (`Z:\...` on Windows via SMB) | Local disk copy | Box copy |
|------|------------------------------------------|------------------|----------|
| Photos | `/mnt/storage/Photos/library/admin/` | `D:\Photos\` | `box:Photos` |
| Documents | `/mnt/storage/Documents/borja/files/` | `D:\Documents\` | `box:Documents` |

## Scheme

| # | Copy | Medium | Location | Role |
|---|------|--------|----------|------|
| 1 | Primary | NFS (external hard drive) | `/mnt/storage/<Photos\|Documents>/...` (mounted as `Z:\...` on Windows via SMB) | Source of truth. Read directly by Immich / Nextcloud. |
| 2 | Local | Local disk on the Windows machine | `D:\Photos\` / `D:\Documents\` | Fast local backup, independent of network/third parties. |
| 3 | Offsite (**paused**) | Cloud (Box, being reconsidered) | `box:Photos` / `box:Documents` | Off-site backup, protects against local hardware failure/theft/fire. Not currently running. |

```
              ┌─────────────────────────────┐        ┌─────────────────────────────┐
              │  NFS: /mnt/storage/Photos   │        │ NFS: /mnt/storage/Documents │
              │  library/admin/<year>/...   │        │      borja/files/...        │
              │  (Z:\Photos\... on Windows) │        │ (Z:\Documents\... on Win.)  │
              └───────────────┬─────────────┘        └───────────────┬─────────────┘
                              │                                      │
                Immich reads  │  rclone (sync-backup.ps1)   Nextcloud│  reads
                directly      │  - pick source in the menu  directly│
                              ▼                                      ▼
                    ┌─────────┴─────────┐                  ┌─────────┴─────────┐
                    ▼                   ▼                  ▼                   ▼
              D:\Photos\...      box:Photos\...      D:\Documents\...   box:Documents\...
              (copy 2)           (copy 3, paused)     (copy 2)           (copy 3, paused)
```

Note: the destinations (Box and local disk) end up **without** the intermediate `admin/` /
`borja/files/` folder — the script copies the *contents* of that folder, so e.g. year folders for
Photos sit directly at the root on both destinations (`Photos/2015/...`, not
`Photos/admin/2015/...`).

## Select what to back up (menu on every run)

After picking Copy or Sync, the script shows a second menu to pick the source:

```
=== Select what to back up ===
  1) Photos     (Z:\Photos\library\admin)
  2) Documents  (Z:\Documents\borja\files)

Enter a number
```

Adding a new source later (e.g. a third NAS folder) just means adding one entry to the
`$Sources` table at the top of the script — no other logic changes.

## Sync mode: Copy vs Sync (menu on every run)

Every time the script runs, it shows a menu:

```
=== Select sync mode ===
  1) Copy  - safe, never deletes anything at the destination (default for regular runs)
  2) Sync  - mirrors the source exactly, DELETES destination files/folders
             that no longer exist at the source (use after renaming/merging albums)

Enter 1 or 2
```

**Copy (option 1)** — the safe default for regular runs (new photos added, nothing reorganized):
- If a file is deleted or renamed at the source (NFS), it is **not** deleted from Box or the
  local disk — it stays there as a backup.
- If albums get reorganized on the NFS without using Sync afterwards, the destinations
  accumulate copies instead of mirroring the exact state of the source.

**Sync (option 2)** — needed after reorganizing albums in Immich (renaming to drop the year,
merging duplicate-artist albums, etc.), since that changes the physical folder names on the NFS
source (via the Storage Template) and a plain Copy would leave the old folder names behind as
orphaned duplicates at the destinations:
- Makes the destination match the source exactly, **including deleting** anything at the
  destination that no longer exists at the source.
- Always previewed first with `--dry-run` automatically — the script prints what would be
  deleted/copied, then asks for an explicit `YES` before doing anything for real. Any other input
  aborts with no changes made.
- Review the `Deleted` lines in the preview carefully before typing `YES` — that's exactly what
  will be removed from Box and/or `D:\Photos`.

Rule of thumb: use **Copy** for routine "I added some photos" runs, and **Sync** right after a
reorganization in Immich (renaming/merging albums), then go back to Copy for the next routine
run.

## Setup

### 1. Install rclone (Windows)

```powershell
winget install Rclone.Rclone
```

Close and reopen a new PowerShell window after installing (so the `PATH` reloads). Verify with:

```powershell
rclone version
```

If `rclone` is still not recognized after reopening the terminal, winget may not have registered
the install location in the `PATH`. Find it and add it manually:

```powershell
Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "rclone.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object FullName
```

```powershell
$rclonePath = (Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "rclone.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).DirectoryName
[Environment]::SetEnvironmentVariable("Path", "$([Environment]::GetEnvironmentVariable('Path','User'));$rclonePath", "User")
```

Close and reopen the terminal again, then retry `rclone version`.

### 2. Why the source is `Z:\`, not an rclone remote

An existing rclone remote called `nas` (SFTP, `192.168.1.217`) was already configured on this
machine from an earlier setup. It was considered as the source instead of the mapped `Z:\`
drive, but ruled out for two reasons:

- **Performance**: in a LAN, SMB (what backs the `Z:\` mapped drive) is generally faster than
  SFTP for bulk transfers — SMB3 supports multichannel and larger buffers, while SFTP has
  per-packet encryption overhead and is designed for secure remote access, not for raw LAN
  throughput.
- **Access**: `rclone lsd nas:` only showed the SFTP user's home directory (`.cache`, `.config`,
  `.ssh`), not the actual storage path — SFTP chroots the user to their home by default, so this
  remote can't currently see `Photos/library/admin` at all without reconfiguring the SFTP server.

Conclusion: keep using `Z:\Photos\library\admin` (the SMB-mapped drive) as the source for the
script. The `nas` remote is left untouched, unused for this purpose.

### 3. Configure the Box remote

Box Sync (the old desktop client) is deprecated — rclone talks to the Box API directly instead,
with no need to create a custom Box app or generate any key manually. rclone ships with its own
OAuth credentials for Box.

**Important**: do this on the Windows machine itself, in a local PowerShell window (not over an
SSH session into a headless Linux VM) — the browser-based Box login below only works where a
browser is actually available.

The interactive `rclone config` wizard was tried first, but hit a terminal/readline glitch: the
`access_token` prompt (which must be left blank) kept getting auto-filled with `1` from an
earlier answer in the same wizard, which made rclone skip the "Use auto config" step entirely (it
thought it already had a token) — so the browser never opened. The fix is to skip the wizard and
create the remote in two explicit steps instead:

**Step 1 — run the OAuth authorization on its own:**

```powershell
rclone authorize "box"
```

This opens the browser for the Box login/authorization. Once done, it prints a JSON block in the
terminal:

```
Paste the following into your remote machine --->
{"access_token":"...","token_type":"bearer","refresh_token":"...","expiry":"..."}
<---End paste
```

**Step 2 — create the remote directly with that token, bypassing the wizard:**

Copy the full JSON (the `{...}` part) and run:

```powershell
rclone config create box box box_sub_type=1 token='PASTE_THE_FULL_JSON_HERE'
```

Verify:

```powershell
rclone lsd box:
```

Should list the root folders of your Box account.

## The script

Location: `D:\Scripts\sync-backup.ps1` (copy kept in the repo as `scripts/sync-backup.ps1`)

What it does:
1. Checks that the source (`Z:\Photos\library\admin`) is reachable (i.e. the SMB drive is
   mounted).
2. Asks which mode to use for this run: Copy or Sync (see "Sync mode: Copy vs Sync" above). If
   Sync is chosen, previews with `--dry-run` and requires typing `YES` to proceed.
3. If `$SyncToBox` is `$true`: runs the chosen mode from the source to `box:Photos`. In Copy
   mode, capped at `$BoxMaxTransfer` per run (see "Limited Box space" below), plus the
   `not-in-box.txt` tracking file. If `$SyncToBox` is `$false`, this whole step is skipped.
4. Runs the chosen mode from the source to `D:\Photos` — always runs, regardless of `$SyncToBox`.
5. Writes one log per leg to `D:\Scripts\logs\`, timestamped.

### Pausing/resuming the cloud copy

The cloud leg (currently Box) can be switched off entirely without touching the rest of the
script — useful while switching providers, without losing the local backup in the meantime.

```powershell
$SyncToBox = $false   # cloud upload skipped, only D:\Photos runs
$SyncToBox = $true     # cloud upload active
```

While `$false`: no connection to Box is made, no `box:` remote is required to be valid, and
`not-in-box.txt` isn't regenerated (it's only relevant while actually uploading to Box). The
local disk sync to `D:\Photos` keeps running either way, so that backup stays current regardless
of what's happening with the cloud provider.

Once a new provider is chosen, update `$BoxDest` (currently `box:Photos`) to point at the new
remote — configure it in rclone first (`rclone config`, following the same idea as the Box setup
above, adapted to whatever the new provider's rclone backend needs), then flip `$SyncToBox` back
to `$true`.

### Limited Box space

The Box account is mid-reorganization and only has a small amount of free space (checked with
`rclone about box:`: 50 GiB total, ~22 GiB used, ~27.8 GiB free at the time of writing) — nowhere
near enough to fit the whole library in one run. To handle this without the transfer failing
outright with a "not enough space" error, the script caps the Box upload with
`--max-transfer $BoxMaxTransfer` (defaults to `25G`, leaving a few GB of safety margin below the
actual free space).

How this plays out:

- Files are copied in alphabetical order (`--order-by name`), so the oldest years upload first
  (`2008`, `2009`, `2010`, ...).
- When the cap is hit, rclone stops cleanly with exit code `7` — the script recognizes this and
  prints a message that this is expected, not a failure.
- The local disk (`D:\Photos`) sync is not capped — it always runs in full.

**Workflow while Box space is tight:**
1. Check current free space: `rclone about box:`
2. Adjust `$BoxMaxTransfer` in the script if the free space differs a lot from the current
   ~27.8 GiB (keep a couple of GB of margin below the real free space).
3. Run the script. It uploads as much as fits, then stops.
4. Free up more space in Box (continue the reorganization/cleanup).
5. Re-run the script. Since it uses `copy`, already-uploaded files are skipped — it resumes with
   the next year/album that didn't fit last time.
6. Repeat steps 3-5 until everything's uploaded, then increase `$BoxMaxTransfer` to a generous
   value (or remove the flag) since it won't matter anymore once there's enough headroom.

### Box's 250MB per-file limit (Personal/Free plan)

Box's Personal/Free plan rejects any single file larger than 250MB outright, with:

```
Failed to copy: pre-upload check: Error "file_size_limit_exceeded" (403):
File size exceeds the folder owner's file size limit
```

This is unrelated to the account's free space or to API rate limits — it's a hard per-file cap
tied to the plan. Checked against the full library (`find ... -size +250M`), only 2 files hit
this today:

- `2016/2016 - Pueblo/Toro de fuego.mov` (618MB)
- `2025/2025 - Concierto - Baby Metal/IMG_4688.mov` (268MB)

The script sets `--max-size $BoxMaxFileSize` (`250M`) on the Box upload so rclone skips these
files cleanly and logs them, instead of wasting time retrying an upload that will never succeed.
They still exist safely on the NFS source and get copied to the local `D:\Photos` backup — they
just won't be present on Box unless the account is upgraded to a plan with a higher per-file
limit (Box Business plans allow much larger files).

### Tracking which files are not on Box

After every run, the script scans the source (`Z:\Photos\library\admin`) for files over 250MB
and writes their folder + filename (nothing else) to:

```
D:\Scripts\logs\not-in-box.txt
```

This file is recalculated from scratch each run (not appended to), so it always reflects the
current state of the source rather than accumulating stale entries. It only lists files that
will *never* make it to Box under the current plan — it does not include files that simply
haven't been uploaded yet because a previous run stopped at the `$BoxMaxTransfer` cap (those get
picked up automatically on the next run).

### Manual run

```powershell
D:\Scripts\sync-backup.ps1
```

(No scheduled task is set up yet — it runs on demand. Automating it with Windows Task Scheduler
is a separate, deliberately-not-done-yet step.)

### Logs

Each run produces two files in `D:\Scripts\logs\`:

- `sync-box_<timestamp>.log`
- `sync-local_<timestamp>.log`

Check these if the script reports a non-zero exit code.

## Requirement for the script to work

The `Z:\` drive (SMB mount of the NAS, backing `/mnt/storage/Photos`) must be connected before
running the script. If it isn't, the script stops with an explicit error instead of failing
halfway through.
