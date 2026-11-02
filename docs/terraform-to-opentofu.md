# OpenTofu for the Proxmox VMs

The VMs in `terraform/` are managed with **OpenTofu** (`tofu`) and the `telmate/proxmox` provider.
OpenTofu reads the same state format and the same `.tf` files as Terraform, so the project needs no
code rewrite. This guide covers the procedure: install, init, plan, apply one VM at a time, and
rollback. Terraform stays installed only as the rollback path.

## Prerequisites

- OpenTofu 1.13.2 (`~/.local/bin/tofu`).
- Provider `telmate/proxmox` `3.0.2-rc10` or newer, pinned once in `terraform/versions.tf`
  (`terraform/vm/versions.tf` only declares the `source`). Provider `3.0.1-rc8` fails against
  Proxmox VE 9 with `permissions for user/token root@pam are not sufficient ... [VM.Monitor]`,
  because `VM.Monitor` no longer exists in Proxmox 9; `3.0.2-rc04` and newer do not require it.
- `terraform/terraform.tfstate`, `terraform/terraform.tfstate.backup` and `terraform/terraform.tfvars`
  are gitignored. Copy them by hand before the first `tofu` run.
- Packer is a separate tool and is not affected.

## 1. Back up

Keep a private copy outside the repo (mode 700 for the folder, 600 for the files, with a
`SHA256SUMS` file):

```bash
~/.local/share/homelab-backups/terraform-pre-opentofu-2026-10-24/
```

It holds `terraform.tfstate`, `terraform.tfstate.backup`, `terraform.tfvars` and the old
`.terraform.lock.hcl`. Commit the code as well.

## 2. Install OpenTofu (no `sudo`)

1. Download `tofu_1.13.2_linux_amd64.zip` from the OpenTofu GitHub release.
2. Check it against the release `SHA256SUMS`.
3. Copy the binary to `~/.local/bin/tofu`.

There is no auto-update: to upgrade, repeat with the new version, or use the apt repository. Remove
with `rm ~/.local/bin/tofu`.

## 3. Initialise

```bash
cd terraform
tofu init -upgrade
```

`.terraform.lock.hcl` is rewritten to `registry.opentofu.org` with new hashes (the registry builds
are not byte-identical to the Terraform ones). Commit the new lock. `hashicorp/null` has no version
constraint, so `-upgrade` takes the newest; it leaves the lock once no `null_resource` remains in
the state.

Two environment variables affect both tools:

- `TF_CLI_CONFIG_FILE=~/.config/terraform/terraformrc`: the file must exist, otherwise every run
  prints `Unable to open CLI configuration file`. An empty file with comments is valid, and it is
  the place for CLI settings.
- `TF_PLUGIN_CACHE_DIR=~/.cache/terraform`: shared by both tools. OpenTofu stores providers under
  `registry.opentofu.org/`, so they do not collide.

## 4. Plan and read it

```bash
tofu plan
```

Before any apply, check that no VM is destroyed or replaced:

```bash
tofu plan | grep -E 'proxmox_vm_qemu.*(destroyed|replaced)'   # must print nothing
```

This read-before-apply check is the safeguard against deleting a VM; the code carries no
`prevent_destroy` or `protection` guard.

## 5. Apply one VM at a time

`-target` on a single VM fails while a `moved` block is pending (`Error: Moved resource instances
excluded by targeting`). When moves are pending, persist them once with a refresh-only apply, which
writes only the state and never touches a VM:

1. Back up the state (the first write by OpenTofu re-stamps it):
   `cp terraform/terraform.tfstate ~/.local/share/homelab-backups/terraform-pre-opentofu-2026-10-24/terraform.tfstate.before-refresh`
2. `tofu apply -refresh-only` and answer `yes`. Expect `0 added, 0 changed, 0 destroyed`.
3. Check `tofu state list`: it shows `terraform_data.docker_compose_setup` and no `null_resource`.

Then, per VM, with a saved plan so that exactly what was reviewed is what is applied:

1. `tofu plan -target='module.vms["sahaquiel"]' -out=/tmp/sahaquiel.tfplan`
2. Review it. It must list only `proxmox_vm_qemu.vm will be updated in-place` and
   `terraform_data.docker_compose_setup must be replaced`, with nothing destroyed or replaced on
   the VM.
3. Compare the VM's `docker-compose.yaml` with the repo. A difference (even only the order of a
   volume line) makes `docker compose up -d` recreate that container. Preview it with
   `docker compose up -d --dry-run`.
4. `tofu apply /tmp/sahaquiel.tfplan`, then `rm /tmp/sahaquiel.tfplan`. A plan file holds the
   provider credentials; never keep it in the repo.
5. Verify: the same targeted plan says `No changes`, the containers of that VM are up, and their
   start times did not change (unless step 3 predicted a recreate).

Order, least critical first: sahaquiel (Uptime Kuma), matarael (Homepage), ramiel, sandalphon,
shamshel, tabris, sachiel, ireul (Immich and the databases), gaghiel (Traefik, the reverse proxy
for everything) last. Lilith is never provisioned (see "Per-VM options").

## Provisioning design

`terraform/vm/provisioner.tf` runs `setup.sh` on each VM through a `terraform_data` resource. It
re-runs only when something it deploys changes:

```hcl
resource "terraform_data" "docker_compose_setup" {
  triggers_replace = {
    vm_uuid    = proxmox_vm_qemu.vm.smbios[0].uuid   # changes only when the VM is rebuilt
    docker_dir = local.docker_dir_hash               # hash of every file in docker/<name>/
    env        = filesha256("${path.root}/.env")
    setup      = filesha256("${path.root}/../scripts/vm-setup.sh")
    backup     = filesha256("${path.root}/../scripts/vm-backup.sh")
  }
  ...
}
```

- A plan is quiet unless the compose files, `.env`, `vm-setup.sh`, `vm-backup.sh` or a rebuilt VM
  change.
- `smbios[0].uuid` is assigned by Proxmox at creation and is stable across edits, so an edited VM is
  not re-provisioned and a rebuilt VM is. `replace_triggered_by = [proxmox_vm_qemu.vm]` is not used
  because it also fires on in-place changes such as a memory edit.
- Changes made by hand inside a VM are not overwritten at every apply. To re-run the setup on one
  VM: `tofu apply -replace='module.vms["gaghiel"].terraform_data.docker_compose_setup'`.
- The state stores the SHA-256 of `.env`, not its content.
- Every VM receives the whole `.env`, Proxmox credentials included.

## Per-VM options

`terraform/terraform.tfvars` holds one `vm_configs` entry per VM. `terraform/variables.tf` defines
the defaults and validations:

| Field | Default | Rule |
|-------|---------|------|
| `cpu_cores` | 2 | >= 1 |
| `cpu_sockets` | 1 | >= 1 |
| `memory` | 2048 (MiB) | >= 512 |
| `disk_size` | `"10G"` | number followed by M, G or T |
| `provision` | `true` | `false` skips `setup.sh`, SSH and the copy of `docker/<name>/` |
| `id`, `name`, `description` | required | `id` unique, between 100 and 999999999; the key must equal `name` |

Each validation error names the offending VM, for example
`memory is in MiB and must be at least 512. Too small in: ramiel`. Run `tofu plan -refresh=false`
to test a change to `terraform.tfvars` quickly.

`provision = false` is for a VM that Terraform only creates and resizes. Lilith uses it: it is a
hand-installed Ubuntu VM that runs the Hermes assistant at OS level, has no Docker, and has no
`docker/lilith/` folder. With `count = var.provision ? 1 : 0` the resource address is
`terraform_data.docker_compose_setup[0]`.

## Resizing a VM

1. Edit `cpu_cores` / `memory` in `terraform.tfvars`.
2. Plan, review, apply.

Hotplug is `network,disk,usb` (no `cpu`, no `memory`), so Proxmox applies a CPU or RAM change only
after a reboot, and `automatic_reboot = true` (the provider default) makes the apply reboot the VM
by itself. Apply at a moment when the services on that VM can be interrupted, or set
`automatic_reboot = false` and reboot manually (the new values stay pending in Proxmox until then).
To change CPU or RAM without a reboot, enable hotplug first
(`hotplug = "network,disk,usb,cpu,memory"` plus `numa = true`); it needs one reboot to take effect,
and shrinking memory live is not reliable.

Lilith's Hermes starts by itself after a reboot: it runs as the user systemd service
`hermes-gateway.service` of `bis`, and `bis` has `Linger=yes`.

`terraform.tfvars` must match the real VM sizes in Proxmox; an apply otherwise resizes the VM to
the file's values at the next restart. Real memory (MB): lilith 4096, sachiel 6144, shamshel 4096,
ramiel 2048, gaghiel 2048, sandalphon 4096, matarael 1024, sahaquiel 1024, ireul 8192, tabris 4096.

## Provider arguments in use

`terraform/vm/main.tf` uses the current provider schema:

| Argument | Note |
|----------|------|
| `description` | Writes the VM notes. The old `desc` argument is deprecated. |
| `start_at_node_boot = true` | Replaces the deprecated `onboot`. |
| `cpu { cores, sockets, type = "host" }` | One block, at most once. The top-level `cores`, `sockets` and `cpu_type` are deprecated and are not mixed with the block. |
| `startup_shutdown { order = -1, startup_delay = -1, shutdown_timeout = -1 }` | Proxmox defaults. The provider always reports the block; declaring it avoids a diff in every plan. |

`tofu validate` reports 0 errors and 0 warnings.

Available but unused:

- `startup_shutdown` with real `order` / `startup_delay`: boot order in code. The israfel-first rule
  is set by hand (`qm set 207 --startup order=1,up=60`) because israfel is not in Terraform.
- `power_state`: declare whether a VM is running or stopped (the older `vm_state` is covered by
  `lifecycle { ignore_changes = [vm_state] }`).
- `ignore` flag on `disk` / `disks`: leaves a disk out of Terraform's control; it could replace the
  `ignore_changes = [disk]` workaround in `vm/main.tf`.
- `proxmox_lxc_guest` (experimental LXC resource).
- `Pool.Audit` is part of the permissions the token needs; it matters only if the API token stops
  being `root@pam`.

Network `rate` is in MB/s and `network.id` needs the `net` prefix internally; `network { id = 0 }`
shows no diff.

## Rollback

Until the first `tofu apply`, the state file is byte-for-byte the one Terraform wrote (compare a
hash before and after `tofu plan`). The first write by OpenTofu re-stamps it with OpenTofu's
version. To roll back:

1. Stop using `tofu`.
2. Restore the backed-up state and the old `.terraform.lock.hcl` from the backup folder.
3. `terraform init`, then `terraform plan`.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| Plan shows memory changes | `terraform.tfvars` differs from Proxmox. Align the file (see "Resizing a VM"). |
| Plan shows `description` overwritten | The module must set `description`, not `desc`. |
| Plan keeps removing a `startup_shutdown` block | Declare the block with the `-1` values. |
| Helper plan matches nothing and the guard aborts | Pass the VM name, not its id, in `-target`. |
| Database starts with "automatic recovery" after a reboot | Set `stop_grace_period: 60s` on that service in its `docker-compose.yaml`. Docker stops each container after `stop_grace_period` (10 s by default); Proxmox already waits up to 180 s for a guest. |
