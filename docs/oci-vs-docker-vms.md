# Proxmox native OCI containers vs Docker inside VMs

Comparison of the two ways to run containerised apps on Proxmox VE 9: Docker Compose stacks inside
Ubuntu VMs, and Proxmox native OCI containers. The homelab uses **Docker in VMs**.

**Docker in VMs is used because** it is stable and runs the Compose stacks as they are. OCI
application containers are a technology preview and cannot yet express what the stacks use. The RAM
saved by OCI is small (about 2-3 GB of 62 GB), and the same order of RAM can be recovered without
changing the runtime (see "Reducing memory without changing runtime").

## How Proxmox OCI containers work

Checked in the docs shipped with Proxmox 9.2.21.

- OCI images run as LXC containers (since 9.1). The image is **converted to a normal LXC
  container** and uses the existing LXC framework. The kernel is the host's: no guest kernel, no
  guest OS.
- **System containers from OCI images** are supported. **Application containers** (one app per
  container, the Docker model) are a technology preview.
- Images are pulled from a registry with the "Pull from OCI registry" button or the API
  (`/nodes/<node>/storage/<storage>/oci-registry-pull`).
- `pct create` options: `entrypoint`, `env`, `dev[n]` (device passthrough), `mp[n]` (mount points),
  `features` (`fuse`, `keyctl`, ...), `net[n]`, `memory`, `swap`, `cores`, `cpulimit`, `cpuunits`,
  `onboot`, `startup`, `protection`, `ha-managed`, `hookscript`.
- Not in that list: restart policy, healthcheck, `depends_on`, stop grace period, logging driver,
  user-defined networks, secrets, compose files. The Proxmox roadmap lists "mature OCI image
  support and declarative multi-guest application support based on the Compose Specification" as
  future work.
- Proxmox recommends nesting containers inside a QEMU VM for "use cases demanding maximum
  isolation and the ability to live-migrate".
- OpenTofu provider 3.0.2-rc10 has `proxmox_lxc` and `proxmox_lxc_guest`, but neither exposes
  `entrypoint` or `env`. An OCI application container cannot be fully defined from code (it needs
  `pct set` in a provisioner).

## Comparison

| | Docker in VMs | Proxmox OCI containers |
|---|---|---|
| RAM overhead | about 300 MB OS per VM, about 2.7 GB for 9 | about 0 (shared kernel) |
| Page cache | trapped in each VM (13 GB) | shared with the host, reclaimable |
| Disk | each VM has an Ubuntu root; Docker images are still needed | images only; saves the OS part (an estimate of 25-35 GB) |
| Maturity | stable | application containers: technology preview |
| Compose stacks (about 35 services) | work as is | not supported; each service becomes its own container |
| Restart on crash, healthchecks, `depends_on`, grace period | yes | no equivalent in the options |
| `network_mode: host` (Jellyfin, Plex) | yes | no; each container has its own NIC and IP |
| VPN containers (gluetun, tailscale), `/dev/net/tun` | works | possible through `dev[n]`, not tested |
| Logs UI (Dozzle agents use the Docker socket) | works | no Docker socket |
| Update flow | `docker compose pull && up -d` | pull the image again and recreate the container |
| Isolation | VM boundary | shared host kernel; Traefik would run next to the hypervisor |
| IaC | OpenTofu manages the VMs, `setup.sh` deploys | provider cannot set `entrypoint` / `env` |
| Backup | `vzdump` of VMs + `~/config` to NFS | `vzdump` of containers; app data needs mount points |

## When to pick which

| Pick | When |
|------|------|
| Docker in VMs | The service ships as a Compose stack, needs restart policy, healthchecks, `depends_on`, host networking or the Docker socket, or needs VM-level isolation. |
| OCI container | The service is a single, stateless app with no Compose needs, and the preview status is acceptable. Start with a disposable, non-internet-facing service. |

Re-check OCI when the Compose-based multi-guest support from the Proxmox roadmap ships.

## Memory measurements

Measured on the host about 3 h after a reboot (MB). Host: 63,675 total, 30,788 used, 32,886
available. KSM is off (`run=0`). Ballooning is effectively off: the code sets `balloon = memory`.

| VM | Allocated | Host RSS of its QEMU | Used inside (no cache) | Page cache inside | Containers (sum) |
|----|----------:|---------------------:|-----------------------:|------------------:|-----------------:|
| lilith (Hermes, outside Docker) | 4096 | 1350 | 709 | 527 | 17 |
| sachiel | 6144 | 6122 | 1388 | 4313 | 1297 |
| shamshel | 4096 | 3540 | 1303 | 2149 | 1621 |
| ramiel | 2048 | 1049 | 374 | 588 | 107 |
| gaghiel | 2048 | 1159 | 400 | 674 | 174 |
| israfel (NFS server) | 4096 | 4070 | n/a | n/a | n/a |
| sandalphon | 4096 | 2023 | 607 | 993 | 596 |
| matarael | 1024 | 1033 | 466 | 484 | 131 |
| sahaquiel | 1024 | 1027 | 467 | 468 | 137 |
| ireul | 8192 | 3877 | 1971 | 1484 | 2124 |
| leliel (HAOS) | 8192 | 1830 | 686 | 753 | 725 |
| tabris | 4096 | 1641 | 755 | 759 | 436 |
| **Total** | **49,152** | **28,721** | **9,126** (11 VMs) | **13,192** | **7,365** |

How to read it:

1. The real workload is small: about 9 GB used inside the VMs, of which about 7.4 GB are
   containers.
2. The large number is page cache, not workload. The host holds about 28.7 GB for the VMs, and it
   grows toward the 49 GB allocated as each guest fills its RAM with cache. The host cannot take
   that memory back because ballooning and KSM are off.
3. OS overhead per VM (guest kernel, systemd, journald, dockerd, containerd, agent) is about
   300 MB. It is estimated from the four smallest Docker VMs, where `used - containers` is 226 to
   335 MB (ramiel 267, gaghiel 226, matarael 335, sahaquiel 330). For 9 Docker VMs that is about
   2.7 GB. For the VMs with big stacks the difference is noise, because `docker stats` and
   `MemAvailable` are not measured the same way.
4. In the smallest VMs the OS costs more than the apps: matarael 335 MB of OS for 131 MB of
   containers, sahaquiel 330 for 137.

### Why Proxmox shows high memory for a VM

Proxmox's "memory used" of a VM is `total - free`, taken from the balloon driver's statistics. Linux
fills free RAM with page cache, and cache does not count as free, so it shows as used. The figure
answers "how much host RAM does this VM occupy", not "how much do its programs use". The balloon
device is present even with fixed memory, and enabling ballooning does not change the formula.

| VM | Proxmox shows | `MemTotal - MemFree` inside | Programs (`MemTotal - MemAvailable`) | Page cache |
|----|--------------:|----------------------------:|-------------------------------------:|-----------:|
| sachiel | 5578 MB (90%) | 5578 | 1396 | 4329 |
| shamshel | 3296 MB (80%) | 3296 | 1321 | 2162 |
| ireul | 3335 MB (40%) | 3336 | 1967 | 1485 |
| matarael | 862 MB (84%) | 862 | 468 | 484 |

Real usage is `MemAvailable`-based: inside a VM, `free -h` (column "available") or Glances.

## Reducing memory without changing runtime

1. **Ballooning.** With `balloon` below `memory`, Proxmox takes memory back only when host RAM use
   is above the target (80% by default, node option); below it, it adds memory to the guests up to
   `memory`. The VMs add up to 49,152 MB of 63,675 MB (77%), so the 80% line is rarely crossed. It
   is an overcommit safety net, not a way to lower day-to-day numbers. `balloon` (the guaranteed
   minimum) must stay above the real working set (`MemTotal - MemAvailable` at its peak); below
   that the guest swaps and, as a last resort, the OOM killer runs.
2. **Right-size oversized VMs.** Allocated vs used: ireul 8192 / 1971, leliel 8192 / 686,
   sachiel 6144 / 1388, lilith 4096 / 709, shamshel 4096 / 1303, sandalphon 4096 / 607,
   tabris 4096 / 755. A memory change needs a reboot of that VM (no memory hotplug): one VM at a
   time, in a quiet moment.
3. **Turn KSM on** so identical Ubuntu VMs share pages (`run=0` today).
4. **Consolidate the tiny VMs** if the number of VMs is a problem: matarael, sahaquiel and gaghiel
   run 2 containers each for about 130-170 MB while their OSes cost about 300 MB. This stays
   Docker Compose.

## Limits of these numbers

- No OCI container was created: the OCI limits come from the documentation and the option list of
  the host, not from running one. "No restart policy / healthcheck" means they are not in the
  options.
- The OS overhead is an estimate from four VMs, and the disk saving is an estimate.
- Memory figures are a snapshot 3 hours after a reboot; the page cache keeps growing.
