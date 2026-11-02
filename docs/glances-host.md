# Glances on the Proxmox host

Glances runs as a web server on the Proxmox host (`server-origin`, `192.168.1.111`, port `61208`).
The Homepage dashboard on matarael reads it to show CPU, memory and CPU temperature of the host
([widgets.yaml](../terraform/docker/matarael/widgets.yaml), `version: 4`). A second Glances at
`192.168.1.100:61208` (the Raspberry Pi) is a different machine and is not covered here.

| Item | Value |
|------|-------|
| Install dir | `/root/glances/` |
| Python venv | `/root/glances/venv` (system Python of the host, 3.13 on Debian 13) |
| Packages | `glances[web]` (4.5.8); exact versions in `/root/glances/requirements.lock` |
| Service | `/etc/systemd/system/glances.service`, `ExecStart=/root/glances/venv/bin/python -m glances -w` |
| API | `http://192.168.1.111:61208/api/4/...` |
| Setup script | [`scripts/proxmox-glances-setup.sh`](../scripts/proxmox-glances-setup.sh) |

## Why a venv, and why `glances[web]`

- Glances lives in a Python virtualenv, and a virtualenv is tied to the system Python version.
  After a Debian major upgrade the old `lib/python3.X/site-packages` is no longer found and the
  service fails in a loop with:

  ```
  /root/glances/venv/bin/python: No module named glances
  ```

  The host then shows `degraded` (`systemctl is-system-running`) with `glances.service` as the
  only failed unit. The fix is to rebuild the venv (next section).
- `glances[web]` is installed instead of `glances[all]`: Homepage only needs the web server and the
  API (`fastapi`, `uvicorn`, `jinja2` come with `[web]`), and `all` pulls about 70 extra packages
  (Kafka, Cassandra, Elasticsearch, InfluxDB, MongoDB, SNMP, Podman...). If a feature is missing,
  add its extra, for example `GLANCES_SPEC='glances[web,containers]'` for the Docker plugin.

## Install or rebuild

Run this for a first install and after every Debian major upgrade. The script does everything in
one go and is safe to run again at any time:

```bash
scp scripts/proxmox-glances-setup.sh root@<proxmox-host>:/root/proxmox-glances-setup.sh
ssh root@<proxmox-host> 'bash /root/proxmox-glances-setup.sh'
# pin a version if you want:  GLANCES_SPEC='glances[web]==4.5.8' bash /root/proxmox-glances-setup.sh
```

What it does:

1. Installs `python3-venv` (Debian 13 does not ship it by default).
2. Moves the old venv to `/root/glances/venv.old` and creates a new one with the current Python.
3. Installs `glances[web]` with `pip` and saves `pip freeze` to `/root/glances/requirements.lock`.
4. Rewrites the systemd unit, `daemon-reload`, `enable`, `restart`.
5. Waits until `http://127.0.0.1:61208/api/4/status` answers and prints the CPU reading.

Delete `/root/glances/venv.old` once Glances works. A venv built on another Python cannot be
reused, so it is not a rollback.

## Verify

```bash
systemctl is-active glances                       # active
systemctl is-system-running                       # running
curl -s http://127.0.0.1:61208/api/4/status       # from the host
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.111:61208/api/4/cpu   # from another machine: 200
journalctl -u glances -n 20                       # when it fails
```

The Homepage widgets on matarael read `http://192.168.1.111:61208/api/4/cpu`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `No module named glances` in `journalctl -u glances` | The venv was built on another Python. Run the setup script. |
