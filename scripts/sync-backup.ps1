#Requires -Version 5.1
<#
  sync-backup.ps1
  Single entry point to back up NAS folders (read via the Z:\ SMB mount) to:
    - a local disk (D:\<Name>)          -> always runs
    - Box, via rclone                   -> only when $SyncToBox is $true (see "Sources" below)

  Menu flow on every run:
    1) Pick what to back up (Photos / Documents / ...)
    2) Pick the mode: Copy (safe, never deletes) or Sync (mirrors exactly, can delete)

  Replaces the old sync-photos.ps1 - same rclone logic, generalized to more than one source.
#>

# ============================ Sources ============================
# Add a new entry here to back up another folder with this same script.
# - Source:         where the real files live on the Z:\ mount (NAS, read-only for this script)
# - LocalDest:      local disk destination (always synced)
# - BoxDest:        Box destination (only synced when SyncToBox is $true)
# - TrackBoxLimits: whether to also refresh a not-in-box-<Name>.txt listing files >250MB
#                    (Box Personal/Free plan per-file limit - see docs/backup-3-2-1.md)
$Sources = [ordered]@{
    "1" = @{
        Name            = "Photos"
        Source          = "Z:\Photos\library\admin"
        LocalDest       = "D:\Photos"
        BoxDest         = "box:Photos"
        TrackBoxLimits  = $true
    }
    "2" = @{
        Name            = "Documents"
        Source          = "Z:\Documents\borja\files"
        LocalDest       = "D:\Documents"
        BoxDest         = "box:Documents"
        TrackBoxLimits  = $false
    }
}

# ============================ Settings ============================
$LogDir         = "D:\Scripts\logs"
$SyncToBox      = $false   # cloud leg paused - see docs/backup-3-2-1.md. Flip to $true once a provider is ready.
$BoxMaxTransfer = "25G"    # cap per run while Box free space is tight
$BoxMaxFileSize = "250M"   # Box Personal/Free plan hard per-file limit

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ============================ Menu: mode ============================
Write-Host ""
Write-Host "=== Select sync mode ===" -ForegroundColor Cyan
Write-Host "  1) Copy  - safe, never deletes anything at the destination (default for regular runs)"
Write-Host "  2) Sync  - mirrors the source exactly, DELETES destination files/folders"
Write-Host "             that no longer exist at the source (use after reorganizing files)"
Write-Host ""
$modeChoice = Read-Host "Enter 1 or 2"

switch ($modeChoice) {
    "1" { $RcloneMode = "copy" }
    "2" { $RcloneMode = "sync" }
    default {
        Write-Host "Invalid option. Aborting." -ForegroundColor Red
        exit 1
    }
}

# ============================ Menu: source ============================
Write-Host ""
Write-Host "=== Select what to back up ===" -ForegroundColor Cyan
foreach ($key in $Sources.Keys) {
    Write-Host ("  {0}) {1}  ({2})" -f $key, $Sources[$key].Name, $Sources[$key].Source)
}
Write-Host ""
$sourceChoice = Read-Host "Enter a number"

if (-not $Sources.Contains($sourceChoice)) {
    Write-Host "Invalid option. Aborting." -ForegroundColor Red
    exit 1
}

$Selected  = $Sources[$sourceChoice]
$Name      = $Selected.Name
$SrcPath   = $Selected.Source
$LocalDest = $Selected.LocalDest
$BoxDest   = $Selected.BoxDest

# ============================ Preconditions ============================
if (-not (Test-Path $SrcPath)) {
    Write-Host "ERROR: source '$SrcPath' is not reachable. Is the Z:\ (SMB) drive mounted?" -ForegroundColor Red
    exit 1
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ============================ Sync mode confirmation ============================
if ($RcloneMode -eq "sync") {
    Write-Host ""
    Write-Host "=== DRY RUN preview for '$Name' -> local disk ($LocalDest) ===" -ForegroundColor Yellow
    rclone sync $SrcPath $LocalDest --dry-run -v

    if ($SyncToBox) {
        Write-Host ""
        Write-Host "=== DRY RUN preview for '$Name' -> Box ($BoxDest) ===" -ForegroundColor Yellow
        rclone sync $SrcPath $BoxDest --dry-run -v --max-size $BoxMaxFileSize
    }

    Write-Host ""
    $confirm = Read-Host "Review the 'Deleted' lines above carefully. Type YES to proceed, anything else aborts"
    if ($confirm -ne "YES") {
        Write-Host "Aborted. No changes made." -ForegroundColor Red
        exit 0
    }
}

# ============================ Box leg (optional) ============================
if ($SyncToBox) {
    $BoxLog = Join-Path $LogDir "sync-box-$Name`_$Timestamp.log"
    Write-Host ""
    Write-Host "Running '$RcloneMode' -> Box ($BoxDest)..." -ForegroundColor Green

    rclone $RcloneMode $SrcPath $BoxDest `
        --max-transfer $BoxMaxTransfer `
        --max-size $BoxMaxFileSize `
        --order-by name `
        -v --log-file $BoxLog

    $boxExit = $LASTEXITCODE
    if ($boxExit -eq 7) {
        Write-Host "Box transfer cap ($BoxMaxTransfer) reached - expected, not a failure. Re-run later to continue." -ForegroundColor Yellow
    } elseif ($boxExit -ne 0) {
        Write-Host "Box sync exited with code $boxExit - check $BoxLog" -ForegroundColor Red
    } else {
        Write-Host "Box sync completed." -ForegroundColor Green
    }

    if ($Selected.TrackBoxLimits) {
        $NotInBox = Join-Path $LogDir "not-in-box-$Name.txt"
        Write-Host "Refreshing $NotInBox (files over $BoxMaxFileSize that will never fit Box's plan limit)..."
        Get-ChildItem -Path $SrcPath -Recurse -File |
            Where-Object { $_.Length -gt 250MB } |
            ForEach-Object { "$($_.DirectoryName)\$($_.Name)" } |
            Set-Content -Path $NotInBox
    }
} else {
    Write-Host ""
    Write-Host "Box leg skipped (`$SyncToBox = `$false)." -ForegroundColor DarkGray
}

# ============================ Local disk leg (always runs) ============================
$LocalLog = Join-Path $LogDir "sync-local-$Name`_$Timestamp.log"
Write-Host ""
Write-Host "Running '$RcloneMode' -> local disk ($LocalDest)..." -ForegroundColor Green

New-Item -ItemType Directory -Force -Path $LocalDest | Out-Null
rclone $RcloneMode $SrcPath $LocalDest -v --log-file $LocalLog

if ($LASTEXITCODE -ne 0) {
    Write-Host "Local sync exited with code $LASTEXITCODE - check $LocalLog" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "Local sync completed." -ForegroundColor Green
Write-Host ""
Write-Host "Done. Logs in $LogDir" -ForegroundColor Cyan
