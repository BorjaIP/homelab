# Proxmox native OCI containers vs Docker inside VMs

Question (2026-10-24): Proxmox VE 9 can run OCI images natively. Is it worth moving the current
setup (Ubuntu VMs running Docker Compose stacks) to it, mainly to save resources?

**Verdict: not now.** The RAM it would save is small (about 2-3 GB of 62 GB); the same order of
RAM can be recovered, and much more, without migrating; and the feature is a technology preview
that cannot yet express what the Compose stacks use. Re-evaluate when Compose support lands.

## What Proxmox actually offers (checked in the docs shipped with this host, 9.2.21)

- **9.1 (2025-11-19)** added OCI images as LXC containers. **9.2 (2026-05-21)** improved them
  (honours the image `User`, mounts a tmpfs on `/dev/shm`).
- An OCI image is **converted to a normal LXC container** ("still uses the existing LXC
  framework"). The kernel is the host's: no guest kernel, no guest OS.
- **System containers from OCI images** are supported. **Application containers (one app per
  container, what Docker users want) are a technology preview.**
- Pulled from a registry with the "Pull from OCI registry" button or the API
  (`/nodes/<node>/storage/<storage>/oci-registry-pull`).
- Options of such a container (`pct create`): `entrypoint`, `env`, `dev[n]` (device passthrough),
  `mp[n]` (mount points), `features` (`fuse`, `keyctl`, ...), `net[n]`, `memory`, `swap`, `cores`,
  `cpulimit`, `cpuunits`, `onboot`, `startup`, `protection`, `ha-managed`, `hookscript`.
- **Not in that list:** restart policy, healthcheck, `depends_on`, stop grace period, logging
  driver, user-defined networks, secrets, compose files. The roadmap lists "mature OCI image
  support and declarative multi-guest application support based on the Compose Specification" as
  **future** work.
- The Proxmox guide itself says: "for use cases demanding maximum isolation and the ability to
  live-migrate, nesting containers inside a Proxmox QEMU VM remains a recommended practice".
- **OpenTofu provider 3.0.2-rc10:** it has `proxmox_lxc` and the new `proxmox_lxc_guest`, but
  neither exposes `entrypoint` or `env`. An OCI application container could not be defined
  completely from code (it would need `pct set` in a provisioner).

## What the current setup costs (measured 2026-10-24, about 3 h after the reboot; MB)

Host: 63,675 total, 30,788 used, 32,886 available. KSM is off (`run=0`). Ballooning is effectively
off: the code sets `balloon = memory`.

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

Reading it:

1. **The real workload is small:** about 9 GB used inside the VMs, of which about 7.4 GB are
   containers.
2. **The big number is cache, not workload.** The host holds about 28.7 GB for the VMs, and it keeps
   growing toward the 49 GB allocated as each guest fills its RAM with page cache (sachiel holds
   4.3 GB of cache and its QEMU already uses 6,122 of 6,144 MB). That is why the Proxmox UI showed
   80% before the reboot and 33% now. The host cannot take that memory back because ballooning and
   KSM are off.
3. **OS overhead per VM** (guest kernel, systemd, journald, dockerd, containerd, agent): the
   cleanest estimate comes from the four smallest Docker VMs, where `used - containers` is 226 to
   335 MB (ramiel 267, gaghiel 226, matarael 335, sahaquiel 330), so **about 300 MB**. For 9
   Docker VMs that is **about 2.7 GB**. For the VMs with big stacks the difference is noise
   (negative values: `docker stats` and `MemAvailable` are not measured the same way), so this is an
   estimate, not a measurement.
4. In the smallest VMs the OS costs more than the apps: matarael 335 MB of OS for 131 MB of
   containers, sahaquiel 330 for 137.

## Comparison

| | Docker in VMs (now) | Proxmox OCI containers |
|---|---|---|
| RAM overhead | about 300 MB OS per VM, about 2.7 GB for 9 | about 0 (shared kernel) |
| Page cache | trapped in each VM (13 GB) | shared with the host, reclaimable |
| Disk | each VM has an Ubuntu root; Docker images are still needed | images only; saves the OS part (an estimate of 25-35 GB, not measured) |
| Maturity | stable | application containers: **technology preview** |
| Compose stacks (about 35 services) | works as is | **not supported**; each service becomes its own container |
| Restart on crash, healthchecks, `depends_on`, grace period | yes | no equivalent in the options |
| `network_mode: host` (Jellyfin, Plex) | yes | no; each container has its own NIC and IP |
| VPN containers (gluetun, tailscale), `/dev/net/tun` | works | possible through `dev[n]`, not tested |
| Logs UI (Dozzle agents use the Docker socket) | works | no Docker socket |
| Update flow | `docker compose pull && up -d` | pull the image again and recreate the container |
| Isolation | VM boundary | shared host kernel; Traefik and the Cloudflare tunnel would run next to the hypervisor |
| IaC | OpenTofu manages the VMs, `setup.sh` deploys | provider cannot set `entrypoint` / `env` |
| Backup | `vzdump` of VMs + `~/config` to NFS | `vzdump` of containers; app data needs mount points |

## What to do instead (not applied; nothing here changes infrastructure)

1. **Ballooning (corrected 2026-10-24).** An earlier version of this page said it would recover
   most of the cache. That was overstated. With `balloon` below `memory` Proxmox only takes memory
   back **when host RAM use is above the target (80% by default, node option)**; below it, it adds
   memory to the guests up to `memory`. Here the VMs add up to 49,152 MB of 63,675 MB (77%), so
   the 80% line would rarely be crossed and nothing would be reclaimed day to day. It is an
   overcommit safety net, not a way to lower today's numbers. If used, `balloon` (the minimum the
   VM is guaranteed) must stay above the real working set (`MemTotal - MemAvailable` at its peak),
   because below that the guest swaps and, as a last resort, the OOM killer runs.
2. **Right-size the oversized VMs.** Allocated vs used: ireul 8192 / 1971, leliel 8192 / 686,
   sachiel 6144 / 1388, lilith 4096 / 709, shamshel 4096 / 1303, sandalphon 4096 / 607,
   tabris 4096 / 755. A memory change needs a reboot of that VM (no memory hotplug), so one VM at a
   time, in a quiet moment.
3. **Turn KSM on** (identical Ubuntu VMs share pages): `run=0` today.
4. **Consolidate the tiny VMs** only if the number of VMs bothers you: matarael, sahaquiel and
   gaghiel run 2 containers each for about 130-170 MB while their OSes cost about 300 MB. That is
   still Docker Compose, with no preview feature involved.
5. **Pilot OCI** with one disposable, stateless service (not an internet-facing one) to learn how
   it behaves, and re-check when the Compose-based multi-guest support in the roadmap ships.

## Why the Proxmox memory numbers look high (checked on 4 VMs)

Proxmox's "memory used" of a VM is `total - free`, taken from the balloon driver's statistics. Linux
keeps free RAM filled with page cache, and cache does not count as "free", so it shows up as used.

| VM | Proxmox shows | `MemTotal - MemFree` inside | What the programs hold (`MemTotal - MemAvailable`) | Page cache |
|----|--------------:|----------------------------:|---------------------------------------------------:|-----------:|
| sachiel | 5578 MB (90%) | 5578 | 1396 | 4329 |
| shamshel | 3296 MB (80%) | 3296 | 1321 | 2162 |
| ireul | 3335 MB (40%) | 3336 | 1967 | 1485 |
| matarael | 862 MB (84%) | 862 | 468 | 484 |

The Proxmox figure equals `total - free` to the megabyte. It is not false: that RAM really is
assigned to the VM on the host (sachiel's QEMU holds 6,122 MB). It answers "how much host RAM does
this VM occupy", not "how much do its programs use". The balloon device is present even with fixed
memory ("it delivers useful information such as how much memory the guest really uses"), and it is
the source of this figure; enabling ballooning does not change the formula.

Real usage is `MemAvailable`-based: inside a VM `free -h` (column "available") or Glances.

## What was not verified

- No OCI container was created: limits come from the documentation and the option list of this
  host, not from running one. "No restart policy / healthcheck" means they are not in the
  options, not that a test failed.
- The OS overhead is an estimate from four VMs; the disk saving is an estimate.
- Memory figures are a snapshot 3 hours after a reboot; the page cache keeps growing.
