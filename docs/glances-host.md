# Glances on the Proxmox host

Glances runs as a web server on the Proxmox host (`server-origin`, `192.168.1.111`, port `61208`).
The Homepage dashboard on matarael reads it to show CPU, memory and CPU temperature of the host
([widgets.yaml](../terraform/docker/matarael/widgets.yaml), `version: 4`). A second Glances at
`192.168.1.100:61208` (the Raspberry Pi) is a different machine and is not covered here.

| Item | Value |
|------|-------|
| Install dir | `/root/glances/` |
| Python venv | `/root/glances/venv` (Python 3.13 since the Proxmox 9 upgrade) |
| Packages | `glances[web]` (Glances 4.5.8 on 2026-10-24); exact versions in `/root/glances/requirements.lock` |
| Service | `/etc/systemd/system/glances.service`, `ExecStart=/root/glances/venv/bin/python -m glances -w` |
| API | `http://192.168.1.111:61208/api/4/...` |
| Setup script | [`scripts/proxmox-glances-setup.sh`](../scripts/proxmox-glances-setup.sh) |

## Why it breaks and how to fix it

Glances lives in a Python virtualenv, and a virtualenv is tied to the system Python version.
Glances was installed on Debian 12 (Python 3.11). The Proxmox 9 upgrade moved the host to Debian 13
(Python 3.13), the old `lib/python3.11/site-packages` was no longer found, and after the reboot the
service failed in a loop with:

```
/root/glances/venv/bin/python: No module named glances
```

That is also why the host showed `degraded` (`systemctl is-system-running`) with `glances.service`
as the only failed unit. **The same will happen at the next Debian major upgrade.** The fix is to
rebuild the venv, which the script does in one go:

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

It is safe to run again at any time. Delete `/root/glances/venv.old` once Glances works (a venv
built on another Python cannot be reused, so it is not a rollback).

## Why `glances[web]` and not `glances[all]`

The previous venv was installed with the `all` extra (Kafka, Cassandra, Elasticsearch, InfluxDB,
MongoDB, SNMP, Podman... about 70 packages). Homepage only needs the web server and the API
(`fastapi`, `uvicorn`, `jinja2` come with `[web]`). If a feature is missing later, add its extra,
for example `GLANCES_SPEC='glances[web,containers]'` for the Docker plugin.

## Rebuilt on 2026-10-24

- Before: Glances 4.3.1, Python 3.11, `glances[all]`, service failing since the reboot. The old
  venv (`venv.old`, 162 MB, Python 3.11) was deleted the same day after checking it was that one.
- After: Glances 4.5.8, Python 3.13, `glances[web]`. Service `enabled` and `active`, 0 failed units,
  host `running`, API v4 answers, 4 temperature sensors (`Composite`, `Sensor 1`, `Tctl`, `edge`),
  and matarael reaches `http://192.168.1.111:61208/api/4/cpu` with HTTP 200.
- The Homepage container on matarael was already `unhealthy` before the upgrade and still is; that
  comes from its own healthcheck and is not related to Glances.

## Checks

```bash
systemctl is-active glances                       # active
curl -s http://127.0.0.1:61208/api/4/status       # from the host
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.111:61208/api/4/cpu   # from another machine: 200
journalctl -u glances -n 20                       # when it fails
```

## Original install notes (2025-05)

The unit file and the `systemctl enable --now glances.service` commands were noted in
`/root/glances/README.md` on the host; they are now reproduced by the script.
