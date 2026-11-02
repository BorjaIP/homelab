#!/bin/bash
# Offline checks for install-syncthing.sh and deploy.sh. They never touch israfel and need no root:
# the installer only prints in --dry-run, and the deploy script is only run with --dry-run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { # check "name" "text that must appear" "output"
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing: $2)" ;; esac
}

bash -n "$HERE/install-syncthing.sh" && ok "install-syncthing.sh syntax" || bad "install-syncthing.sh syntax"
bash -n "$HERE/deploy.sh" && ok "deploy.sh syntax" || bad "deploy.sh syntax"

out=$("$HERE/install-syncthing.sh" --dry-run 2>&1); code=$?
[ "$code" -eq 0 ] && ok "dry run exits 0 without root" || bad "dry run exit code $code"
check "uses the official channel" "https://apt.syncthing.net/ syncthing stable-v2" "$out"
check "downloads the release key" "https://syncthing.net/release-key.gpg" "$out"
check "creates the service user" "would create system user syncthing" "$out"
check "creates the data folder" "would create /mnt/storage/PKM" "$out"
check "waits for the disk" "RequiresMountsFor=/mnt/storage" "$out"
check "limits CPU and memory" "GOMAXPROCS=1, MemoryMax=512M" "$out"
check "GUI stays on loopback" "127.0.0.1:8384" "$out"

out=$(SYNC_DATA=/mnt/storage/Other SYNC_MEMORY_MAX=256M "$HERE/install-syncthing.sh" --dry-run 2>&1)
check "env overrides data folder" "would create /mnt/storage/Other" "$out"
check "env overrides memory cap" "MemoryMax=256M" "$out"

"$HERE/install-syncthing.sh" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown option exits 2" || bad "unknown option"

out=$("$HERE/deploy.sh" --dry-run 2>&1); code=$?
[ "$code" -eq 0 ] && ok "deploy dry run exits 0" || bad "deploy dry run exit code $code"
check "deploy targets the ssh alias" "israfel-nfs" "$out"
check "deploy dry run lists the installer steps" "would run: apt-get update" "$out"

bash -n "$HERE/configure-syncthing.sh" && ok "configure-syncthing.sh syntax" || bad "configure-syncthing.sh syntax"
out=$("$HERE/configure-syncthing.sh" --dry-run 2>&1); code=$?
[ "$code" -eq 0 ] && ok "configure dry run exits 0 without root" || bad "configure dry run exit code $code"
check "turns off the internet features" "globalAnnounceEnabled=false relaysEnabled=false natEnabled=false" "$out"
check "GUI moves to the LAN address with TLS" "tls=true" "$out"
check "GUI address default" "address=192.168.1.207:8384" "$out"
check "password goes to a 600 file, never printed" "(mode 600)" "$out"
check "hash is verified" "bcrypt hash" "$out"
case "$out" in *password=*) bad "dry run prints a password" ;; *) ok "dry run prints no password" ;; esac
"$HERE/configure-syncthing.sh" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "configure unknown option exits 2" || bad "configure unknown option"

out=$("$HERE/deploy.sh" --dry-run --only configure 2>&1); code=$?
[ "$code" -eq 0 ] && ok "deploy --only configure exits 0" || bad "deploy --only configure exit code $code"
check "deploy --only configure runs the configure step" "would run on israfel-nfs: bash /root/configure-syncthing.sh" "$out"
case "$out" in *install-syncthing.sh*) bad "--only configure also touches the installer" ;; *) ok "--only configure skips the installer" ;; esac
"$HERE/deploy.sh" --only bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "deploy rejects an unknown step" || bad "deploy unknown step"

[ $fail -eq 0 ] && echo "all checks passed" || { echo "SOME CHECKS FAILED"; exit 1; }
