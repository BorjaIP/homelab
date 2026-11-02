#!/usr/bin/env python3
"""Applies the PKM vault folder to ONE Syncthing instance through its REST API (standard library only).

Idempotent: running it again changes nothing. After every write it reads the value back and fails when it
differs, because the REST API silently ignores JSON fields it does not know (that hid a wrong field name once).
The API key is read from the instance's config.xml and is never printed.

Run it on the host that owns the instance (pair-pkm.sh does that over ssh):

  configure_pkm.py --config PATH --path DIR --peer ID,NAME,ADDRESS [--peer ...] [--ignore-perms]
                   [--staggered-days N] [--print-id] [--dry-run]
"""
import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

FOLDER_ID = "pkm-vault"
FOLDER_LABEL = "pkm"
# Obsidian settings are per machine and change constantly.
IGNORES = [".obsidian"]
OPTIONS = {"globalAnnounceEnabled": False, "relaysEnabled": False, "natEnabled": False}


class Api:
    def __init__(self, config_path):
        gui = ET.parse(config_path).getroot().find("gui")
        scheme = "https" if gui.get("tls") == "true" else "http"
        self.base = f"{scheme}://{gui.findtext('address')}"
        self.key = gui.findtext("apikey")
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE  # self-signed certificate of the local instance

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("X-API-Key", self.key)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=15, context=self.ctx) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            raise SystemExit(f"{method} {path} -> HTTP {e.code}")
        return json.loads(raw) if raw else None


def folder_spec(api, my_id, path, peers, ignore_perms, staggered_days):
    spec = api.call("GET", "/rest/config/defaults/folder")
    spec.update({
        "id": FOLDER_ID, "label": FOLDER_LABEL, "path": path, "type": "sendreceive",
        "devices": [{"deviceID": d, "introducedBy": "", "encryptionPassword": ""} for d in [my_id] + [p[0] for p in peers]],
        "fsWatcherEnabled": True, "ignorePerms": ignore_perms,
    })
    if staggered_days:
        spec["versioning"] = {"type": "staggered", "cleanupIntervalS": 3600, "fsPath": "", "fsType": "basic",
                              "params": {"cleanInterval": "3600", "maxAge": str(staggered_days * 86400)}}
    else:
        spec["versioning"] = {"type": "", "params": {}, "cleanupIntervalS": 3600, "fsPath": "", "fsType": "basic"}
    return spec


def verify(api, spec, peers):
    got = api.call("GET", f"/rest/config/folders/{FOLDER_ID}")
    bad = []
    for key in ("path", "type", "ignorePerms", "fsWatcherEnabled"):
        if got.get(key) != spec[key]:
            bad.append(f"{key}: stored {got.get(key)!r}, wanted {spec[key]!r}")
    if sorted(d["deviceID"] for d in got.get("devices", [])) != sorted(d["deviceID"] for d in spec["devices"]):
        bad.append("devices differ")
    if got.get("versioning", {}).get("type") != spec["versioning"]["type"]:
        bad.append("versioning type differs")
    if spec["versioning"]["type"] and got["versioning"].get("params") != spec["versioning"]["params"]:
        bad.append("versioning params differ")
    ign = api.call("GET", f"/rest/db/ignores?folder={FOLDER_ID}").get("ignore") or []
    if [i for i in ign if i.strip()] != IGNORES:
        bad.append(f"ignore patterns: stored {ign!r}, wanted {IGNORES!r}")
    opts = api.call("GET", "/rest/config/options")
    for key, value in OPTIONS.items():
        if opts.get(key) != value:
            bad.append(f"option {key}: stored {opts.get(key)!r}, wanted {value!r}")
    for dev_id, _name, addr in peers:
        stored = api.call("GET", f"/rest/config/devices/{dev_id}")
        if addr not in stored.get("addresses", []):
            bad.append(f"device {dev_id[:7]} address {addr!r} not stored")
    if bad:
        raise SystemExit("verification failed:\n  " + "\n  ".join(bad))


def apply(api, path, peers, ignore_perms, staggered_days):
    my_id = api.call("GET", "/rest/system/status")["myID"]
    api.call("PATCH", "/rest/config/options", OPTIONS)
    for dev_id, name, addr in peers:
        dev = api.call("GET", "/rest/config/defaults/device")
        dev.update({"deviceID": dev_id, "name": name, "addresses": [addr], "paused": False})
        api.call("PUT", f"/rest/config/devices/{dev_id}", dev)
    spec = folder_spec(api, my_id, path, peers, ignore_perms, staggered_days)
    api.call("PUT", f"/rest/config/folders/{FOLDER_ID}", spec)
    api.call("POST", f"/rest/db/ignores?folder={FOLDER_ID}", {"ignore": IGNORES})
    if any(f.get("id") == "default" for f in api.call("GET", "/rest/config/folders")):
        api.call("DELETE", "/rest/config/folders/default")
    verify(api, spec, peers)


def parse_peer(text):
    parts = text.split(",", 2)
    if len(parts) != 3 or not all(parts):
        raise argparse.ArgumentTypeError("use ID,NAME,ADDRESS")
    return tuple(parts)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True)
    ap.add_argument("--path")
    ap.add_argument("--peer", action="append", type=parse_peer, default=[])
    ap.add_argument("--ignore-perms", action="store_true")
    ap.add_argument("--staggered-days", type=int, default=0)
    ap.add_argument("--print-id", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    if a.print_id:
        print(Api(a.config).call("GET", "/rest/system/status")["myID"])
        return 0
    if not a.path or not a.peer:
        ap.error("--path and at least one --peer are required")
    if a.dry_run:  # prints the plan without touching (or even opening) the instance
        print(f"would set options {OPTIONS}")
        for dev_id, name, addr in a.peer:
            print(f"would add device {name} ({dev_id[:7]}...) at {addr}")
        print(f"would share folder {FOLDER_ID} at {a.path} (sendreceive, ignorePerms={a.ignore_perms}, "
              f"staggered days={a.staggered_days or 'off'}), ignoring {IGNORES}")
        return 0
    apply(Api(a.config), a.path, a.peer, a.ignore_perms, a.staggered_days)
    print(f"ok: folder {FOLDER_ID} at {a.path} shared with {', '.join(p[1] for p in a.peer)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
