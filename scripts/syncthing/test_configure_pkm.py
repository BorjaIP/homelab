"""Offline tests for configure_pkm.py against a small in-memory stand-in for the Syncthing REST API.

Run: python3 -I -m unittest scripts/syncthing/test_configure_pkm.py   (or run this file)
Nothing here contacts a real Syncthing.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import configure_pkm as tool  # noqa: E402

MY_ID = "MYDEVICE-AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG"
PEER_ID = "PEERDEV-1111111-2222222-3333333-4444444-5555555-6666666-7777777"


class Fake(BaseHTTPRequestHandler):
    state = None  # set per test: dict with folders, devices, options, ignores, drop, log

    def log_message(self, *a):
        pass

    def _send(self, obj=None, code=200):
        raw = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n)) if n else None

    def _route(self, method):
        s = self.state
        if self.headers.get("X-API-Key") != "KEY":
            return self._send({"error": "forbidden"}, 403)
        path = self.path
        s["log"].append((method, path))
        if path == "/rest/system/status":
            return self._send({"myID": MY_ID})
        if path == "/rest/config/defaults/folder":
            return self._send({"id": "", "rescanIntervalS": 3600, "ignorePerms": False, "type": "sendreceive"})
        if path == "/rest/config/defaults/device":
            return self._send({"deviceID": "", "compression": "metadata", "addresses": ["dynamic"]})
        if path == "/rest/config/options":
            if method == "PATCH":
                s["options"].update(self._body())
                return self._send()
            return self._send(s["options"])
        if path.startswith("/rest/config/devices/"):
            dev_id = path.rsplit("/", 1)[1]
            if method == "PUT":
                s["devices"][dev_id] = self._body()
                return self._send()
            return self._send(s["devices"][dev_id])
        if path == "/rest/config/folders" and method == "GET":
            return self._send(list(s["folders"].values()))
        if path.startswith("/rest/config/folders/"):
            fid = path.rsplit("/", 1)[1]
            if method == "PUT":
                body = self._body()
                for field in s["drop"]:
                    body.pop(field, None)  # a server that ignores a field it does not know
                s["folders"][fid] = body
                return self._send()
            if method == "DELETE":
                s["folders"].pop(fid, None)
                return self._send()
            return self._send(s["folders"][fid])
        if path.startswith("/rest/db/ignores"):
            if method == "POST":
                s["ignores"] = self._body()["ignore"]
                return self._send()
            return self._send({"ignore": s["ignores"], "expanded": []})
        return self._send({"error": path}, 404)

    def do_GET(self): self._route("GET")
    def do_PUT(self): self._route("PUT")
    def do_POST(self): self._route("POST")
    def do_PATCH(self): self._route("PATCH")
    def do_DELETE(self): self._route("DELETE")


class ConfigurePkm(unittest.TestCase):
    def setUp(self):
        Fake.state = {"folders": {"default": {"id": "default", "path": "~/Sync"}}, "devices": {}, "options": {},
                      "ignores": [], "drop": [], "log": []}
        self.server = HTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = os.path.join(self.tmp.name, "config.xml")
        with open(self.config, "w") as f:
            f.write(f'<configuration><gui enabled="true" tls="false"><address>127.0.0.1:{self.server.server_port}'
                    "</address><apikey>KEY</apikey></gui></configuration>")

    def run_tool(self, *extra):
        argv = ["--config", self.config, "--path", "/data/PKM", "--peer", f"{PEER_ID},lilith,tcp://192.168.1.202:22000", *extra]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = tool.main(argv)
        return code, out.getvalue()

    def test_applies_folder_devices_ignores_and_options(self):
        code, out = self.run_tool("--ignore-perms", "--staggered-days", "90")
        s = Fake.state
        self.assertEqual(code, 0)
        folder = s["folders"]["pkm-vault"]
        self.assertEqual(folder["path"], "/data/PKM")
        self.assertEqual(folder["type"], "sendreceive")
        self.assertTrue(folder["ignorePerms"])
        self.assertEqual(sorted(d["deviceID"] for d in folder["devices"]), sorted([MY_ID, PEER_ID]))
        self.assertEqual(folder["versioning"]["type"], "staggered")
        self.assertEqual(folder["versioning"]["params"]["maxAge"], str(90 * 86400))
        self.assertEqual(s["ignores"], [".obsidian"])
        self.assertEqual(s["devices"][PEER_ID]["addresses"], ["tcp://192.168.1.202:22000"])
        self.assertFalse(s["options"]["globalAnnounceEnabled"] or s["options"]["relaysEnabled"] or s["options"]["natEnabled"])
        self.assertIn("ok:", out)

    def test_removes_the_default_folder(self):
        self.run_tool()
        self.assertNotIn("default", Fake.state["folders"])

    def test_without_versioning_it_is_off(self):
        self.run_tool()
        self.assertEqual(Fake.state["folders"]["pkm-vault"]["versioning"]["type"], "")

    def test_running_twice_stores_the_same_thing(self):
        self.run_tool("--staggered-days", "90")
        first = json.dumps(Fake.state["folders"]["pkm-vault"], sort_keys=True)
        self.run_tool("--staggered-days", "90")
        self.assertEqual(json.dumps(Fake.state["folders"]["pkm-vault"], sort_keys=True), first)

    def test_fails_when_the_server_ignores_a_field(self):
        Fake.state["drop"] = ["ignorePerms"]
        with self.assertRaises(SystemExit) as cm:
            self.run_tool("--ignore-perms")
        self.assertIn("verification failed", str(cm.exception))
        self.assertIn("ignorePerms", str(cm.exception))

    def test_wrong_api_key_is_an_error(self):
        with open(self.config) as f:
            xml = f.read().replace("<apikey>KEY</apikey>", "<apikey>NOPE</apikey>")
        with open(self.config, "w") as f:
            f.write(xml)
        with self.assertRaises(SystemExit):
            self.run_tool()

    def test_print_id_prints_only_the_id_and_never_the_key(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            tool.main(["--config", self.config, "--print-id"])
        self.assertEqual(out.getvalue().strip(), MY_ID)

    def test_dry_run_changes_nothing(self):
        before = json.dumps(Fake.state["folders"], sort_keys=True)
        code, out = self.run_tool("--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(json.dumps(Fake.state["folders"], sort_keys=True), before)
        self.assertEqual([c for c in Fake.state["log"] if c[0] != "GET"], [])
        self.assertIn("would share folder pkm-vault", out)

    def test_peer_needs_three_parts(self):
        with self.assertRaises(SystemExit):
            tool.main(["--config", self.config, "--path", "/x", "--peer", "only-two,parts"])


if __name__ == "__main__":
    unittest.main()
