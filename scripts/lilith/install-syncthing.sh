#!/bin/bash
# Installs Syncthing for the current user (no root) from the official GitHub release and runs it as a systemd
# user service. The version is pinned and equal to the one on israfel. Run it on lilith as bis; deploy-syncthing.sh
# copies it there and runs it.
#
# Checks: the tarball must match the sha256 in the release's sha256sum.txt.asc, and when gpg is available that
# file's signature must verify against the release key published at syncthing.net.
#
# Usage: install-syncthing.sh [--dry-run]
# Env:   SYNCTHING_VERSION (default 2.1.7), DEST_DIR (default ~/.local/bin)
set -euo pipefail

VERSION="${SYNCTHING_VERSION:-2.1.7}"
DEST_DIR="${DEST_DIR:-$HOME/.local/bin}"
BASE="https://github.com/syncthing/syncthing/releases/download/v${VERSION}"
ASSET="syncthing-linux-amd64-v${VERSION}.tar.gz"
UNIT_DIR="$HOME/.config/systemd/user"
RELEASE_KEY_FPR=FBA2E162F2F44657B38F0309E5665F9BD5970C47

dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

die() { echo "install-syncthing: $*" >&2; exit 1; }

unit() {
  cat <<EOF
[Unit]
Description=Syncthing (PKM vault sync)
After=network-online.target

[Service]
# No browser, no restart wrapper, no self-upgrade (the version is pinned by this repo), no default ~/Sync folder.
Environment=STNORESTART=yes STNOUPGRADE=yes STNODEFAULTFOLDER=yes GOMAXPROCS=1
ExecStart=%h/.local/bin/syncthing serve --no-browser
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
}

if [ $dry -eq 1 ]; then
  echo "would download $BASE/$ASSET and $BASE/sha256sum.txt.asc"
  echo "would check the sha256 of the tarball, and the signature of sha256sum.txt.asc if gpg is installed"
  echo "would install the binary to $DEST_DIR/syncthing"
  echo "would write $UNIT_DIR/syncthing.service and run: systemctl --user enable --now syncthing.service"
  echo "GUI stays on 127.0.0.1:8384"
  exit 0
fi

[ "$(uname -m)" = x86_64 ] || die "unsupported architecture $(uname -m)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "install-syncthing: downloading v$VERSION"
curl -fsSL -o "$tmp/$ASSET" "$BASE/$ASSET"
curl -fsSL -o "$tmp/sha256sum.txt.asc" "$BASE/sha256sum.txt.asc"

expected=$(awk -v a="$ASSET" '$2 == a {print $1}' "$tmp/sha256sum.txt.asc")
actual=$(sha256sum "$tmp/$ASSET" | awk '{print $1}')
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then die "checksum mismatch, nothing installed"; fi
echo "install-syncthing: sha256 OK"

if command -v gpg >/dev/null 2>&1; then
  curl -fsSL -o "$tmp/release-key.gpg" https://syncthing.net/release-key.gpg
  GNUPGHOME="$tmp/gnupg"; export GNUPGHOME; mkdir -m 700 "$GNUPGHOME"
  gpg --batch -q --import "$tmp/release-key.gpg" 2>/dev/null
  # The release file carries two signatures and one key is not published, so gpg exits 2 even when the
  # known one is good: read the status lines (captured, not piped: a pipe with grep -q breaks under pipefail)
  # and require a valid signature by the pinned key (seen 2026-11-02, "Syncthing Release Management").
  status=$(gpg --batch --status-fd 1 --verify "$tmp/sha256sum.txt.asc" 2>/dev/null || true)
  case "$status" in
    *"VALIDSIG "*"$RELEASE_KEY_FPR"*) echo "install-syncthing: signature OK (key $RELEASE_KEY_FPR)" ;;
    *) die "no valid signature by the pinned release key on sha256sum.txt.asc" ;;
  esac
else
  echo "install-syncthing: gpg not installed, signature not checked (checksum only)"
fi

tar -xzf "$tmp/$ASSET" -C "$tmp"
mkdir -p "$DEST_DIR" "$UNIT_DIR"
install -m 755 "$tmp/syncthing-linux-amd64-v${VERSION}/syncthing" "$DEST_DIR/syncthing.new"
mv "$DEST_DIR/syncthing.new" "$DEST_DIR/syncthing"
echo "install-syncthing: $("$DEST_DIR/syncthing" --version | head -1)"

unit > "$UNIT_DIR/syncthing.service"
systemctl --user daemon-reload
systemctl --user enable --now syncthing.service

for _ in $(seq 1 40); do
  if curl -s -o /dev/null http://127.0.0.1:8384/; then break; fi
  sleep 1
done
systemctl --user is-active syncthing.service
curl -s -o /dev/null -w 'GUI http://127.0.0.1:8384 -> HTTP %{http_code}\n' http://127.0.0.1:8384/ || die "GUI does not answer"
