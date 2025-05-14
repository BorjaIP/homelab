<div align="center">
  <h1> Homelab</h1>
  <p><strong>A fully automated, themed homelab built with Proxmox, Terraform, and Docker.</strong></p>
</div>

---
- [System Configuration](#system-configuration)
  - [🔑 SSH Key \& Certificate Generation](#-ssh-key--certificate-generation)
  - [🌐 Proxy Configuration (Traefik)](#-proxy-configuration-traefik)
  - [📁 NFS Configuration](#-nfs-configuration)
    - [Optional - Share Storage](#optional---share-storage)
    - [1. Install NFS Server](#1-install-nfs-server)
    - [2. Add NFS Storage to Proxmox](#2-add-nfs-storage-to-proxmox)
  - [🧱 Base VMs with Packer](#-base-vms-with-packer)
  - [🚀 VM Deployment with Terraform](#-vm-deployment-with-terraform)
  - [🧪 Testing](#-testing)
  - [🔗 References](#-references)

This homelab infrastructure is centered on **Proxmox VE** using **Terraform** and **Docker** to provision VMs and Dockers (*names based in the Angels from Neon Genesis Evangelion*). Each VM serves a specific purpose like media, storage, or network automation.

# System Configuration

> Refer to the table below for an at-a-glance view of each configured and planned virtual machine and its corresponding role.

These steps are tailored specifically to my homelab infrastructure. Some assumptions are made (like Proxmox being pre-installed), and tools are selected based on personal preference and workflow. Your configuration may vary depending on your hardware, network design, and requirements.

- [Proxmox VE](https://proxmox.com/en/products/proxmox-virtual-environment/get-started) is already installed and fully configured in this environment.
- Create new SSH Key for setup conectivity.
- Use [Proxmox VE Helper Scripts](https://community-scripts.github.io/ProxmoxVE/) for community-contributed helper scripts for VM management, backups, and more.
- Setup [Traefik](https://github.com/traefik/traefik) as a reverse proxy to handle and redirect HTTP/S traffic.

## 🔑 SSH Key & Certificate Generation

Generate an SSH key for your cloud-init or other services:

```bash
ssh-keygen -t ed25519 -C "server"
```

Use the generated public key in `user-data` for automatic authentication setup.

## 🌐 Proxy Configuration (Traefik)

Using [traefik-kop](https://github.com/jittering/traefik-kop), each VM runs an agent that:

- Registers itself with the main Traefik instance
- Sends its routing configuration dynamically

This enables:

- Auto-discovery of services
- Clean URLs and HTTPS support
- Centralized control over routing logic

```text
                       
                      +-------------------------+         +---------------------0----+
                      | +---------------------+ |         | +---------------------+  |
                      | |                     | |         | |                     |  |
+---------+     :443  | |  +---------+        | | :8088   | |  +------------+     |  |
|   WAN   |--------------->| traefik |<-------------------->|  | svc-nginx  |     |  |
+---------+           | |  +---------+        | |         | |  +------------+     |  |
                      | |       |             | |         | |                     |  |
                      | |  +---------+        | |         | |  +-------------+    |  |
                      | |  |  redis  |<-------------------->|  | traefik-kop |    |  |
                      | |  +---------+        | |         | |  +-------------+    |  |
                      | |             docker1 | |         | |             docker2 |  |
                      | +---------------------+ |         | +---------------------+  |
                      |                     vm1 |         |                    vm2   |
                      +-------------------------+         +--------------------------+
```

## 📁 NFS Configuration

### Optional - Share Storage

> [!Note]
> ⚠️ NTFS support is functional but comes with performance and permission caveats—consider ext4/ZFS for native setups.

To consolidate data across VMs, I export a shared storage path via NFS, backed by an NTFS-formatted disk. While not typical in Linux-first setups, this suits my personal needs.

```bash
sudo apt install -y ntfs-3g
```

List all the devices and select which one you need to mount.

```bash
sudo fdisk -l
sudo lsblk -f
ls -l /dev/disk/by-uuid/
```

Copy the UUID in /etc/fstab

```bash
# edit fstab
vim /etc/fstab
UUID="" /mnt/storage ntfs-3g defaults,auto 0 0
mkdir /mnt/storage
# mount disc
mount -a
```

- Add disk to VM.

```bash
ls -l /dev/disk/by-id/
qm set 103 -virtio2 /dev/disk/by-id/<disk-id>
```

### 1. Install NFS Server

```bash
sudo apt install -y nfs-kernel-server
sudo vim /etc/exports
```

Example export entry:

```bash
/mnt/storage 192.168.1.0/24(rw,sync,no_subtree_check)
```

> - Replace 192.168.1.0/24 with the subnet of your Proxmox server (e.g., 192.168.1.0/24 allows all IPs in the 192.168.1.x range).
> - rw: Allows read and write access.
> - sync: Ensures changes are written to disk before the client is notified.
> - no_subtree_check: Prevents subtree checking for better performance.

### 2. Add NFS Storage to Proxmox

1. Login to Proxmox Web UI
2. Navigate to `Datacenter > Storage > Add > NFS`
3. Fill in:

    * **ID**: Enter a name for the storage (e.g., nfs-storage).
    * **Server**: Enter the IP address of the NFS server (e.g., 192.168.1.111).
    * **Export**: Click Query to list available NFS exports, and select /mnt/storage.
    * **Content**: Select the types of content you want to store (e.g., Disk image, ISO image, Backup).
    * **Nodes**: Select the Proxmox nodes that can access this storage.

## 🧱 Base VMs with Packer

> [!Warning]
> ⚠️ To be able to run packer from WSL2 you need to change the network mode.

All virtual machines are built from a `cloud-init` Ubuntu 24.04 image using Packer. This ensures consistency across deployments.

Configure `variables.auto.pkrvars.hcl` file for custom values.

```bash
cd packer
packer validate .
packer build .
```

- The resulting image is uploaded to Proxmox as a VM template.
- Cloud-init is enabled in the build to support dynamic configuration.
- Include Docker installation an other tools.
- This template is later used by Terraform to deploy actual VMs.

## 🚀 VM Deployment with Terraform

Deploy or destroy VMs using Terraform's targeted apply.

Ensure that your `terraform.tfvars` and modules are configured per [Proxmox Provider](https://registry.terraform.io/providers/Telmate/proxmox/latest/docs) standards.

```bash
cd terraform
terraform plan
terraform apply
# or 
terraform apply -target='module.vms["ramiel"]'
terraform destroy -target='module.vms["ramiel"]'
```

<div align="center">
  <h2>📦 VMs</h2>
</div>

<div style="display: flex; justify-content: center; width: 100%;">
  <table style="width: 100%; max-width: 1000px; border-collapse: collapse; font-family: sans-serif; font-size: 14px;">
    <thead>
      <tr style="">
        <th style="padding: 8px; border: 1px solid #ccc;">Thumbnail</th>
        <th style="padding: 8px; border: 1px solid #ccc;">VM Name</th>
        <th style="padding: 8px; border: 1px solid #ccc;">ID</th>
        <th style="padding: 8px; border: 1px solid #ccc;">Category</th>
        <th style="padding: 8px; border: 1px solid #ccc;">Services/Tools</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/e/e8/OP_angel_sachiel_face_clean.jpg/300px-OP_angel_sachiel_face_clean.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Adam</td>
        <th style="padding: 8px; border: 1px solid #ccc;">201</th>
        <td style="padding: 8px; border: 1px solid #ccc;">Proxmox Host</td>
        <td style="padding: 8px; border: 1px solid #ccc;">Proxmox VE</td>
      </tr>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/e/e1/M25_Lilith_Cross_Ritsuko.jpg/175px-M25_Lilith_Cross_Ritsuko.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Lilith</td>
        <th style="padding: 8px; border: 1px solid #ccc;">202</th>
        <td style="padding: 8px; border: 1px solid #ccc;">Storage</td>
        <td style="padding: 8px; border: 1px solid #ccc;">TrueNAS*</td>
      </tr>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/d/d9/Sachiel_Monitor.jpg/175px-Sachiel_Monitor.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Sachiel</td>
        <th style="padding: 8px; border: 1px solid #ccc;">203</th>
        <td style="padding: 8px; border: 1px solid #ccc;">Media Server</td>
        <td style="padding: 8px; border: 1px solid #ccc;">Plex / Jellyfin / Plextraktsync / Navidrome</td>
      </tr>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/e/ec/03_C208_shamshel-comp_crop.jpg/150px-03_C208_shamshel-comp_crop.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Shamshel</td>
        <th style="padding: 8px; border: 1px solid #ccc;">204</th>
        <td style="padding: 8px; border: 1px solid #ccc;">Arr Stack</td>
        <td style="padding: 8px; border: 1px solid #ccc;">Sonarr / Radarr / Lidarr / Prowlarr / Overseerr</td>
      </tr>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/7/75/Ramiel_110.jpg/175px-Ramiel_110.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Ramiel</td>
        <th style="padding: 8px; border: 1px solid #ccc;">205</th>
        <td style="padding: 8px; border: 1px solid #ccc;">Downloaders</td>
        <td style="padding: 8px; border: 1px solid #ccc;">Transmission</td>
      </tr>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/4/4c/Ep08_gaghiel.jpg/175px-Ep08_gaghiel.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Gaghiel</td>
        <th style="padding: 8px; border: 1px solid #ccc;">206</th>
        <td style="padding: 8px; border: 1px solid #ccc;">Reverse Proxy and Tunnels</td>
        <td style="padding: 8px; border: 1px solid #ccc;">Traefik / CloudflareTunnels</td>
      </tr>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/8/8d/09_C346_israfel-2jump.jpg/175px-09_C346_israfel-2jump.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Israfel</td>
        <th style="padding: 8px; border: 1px solid #ccc;">207</th>
        <td style="padding: 8px; border: 1px solid #ccc;">NFS Server</td>
        <td style="padding: 8px; border: 1px solid #ccc;">NFS*</td>
      </tr>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/6/6d/Ep10_sandalphon.jpg/175px-Ep10_sandalphon.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Sandalphon</td>
        <th style="padding: 8px; border: 1px solid #ccc;">208</th>
        <td style="padding: 8px; border: 1px solid #ccc;">Network tools</td>
        <td style="padding: 8px; border: 1px solid #ccc;">Gluetun / Flaresolverr</td>
      </tr>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/2/28/11_C337_matarael.jpg/175px-11_C337_matarael.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Matarael</td>
        <th style="padding: 8px; border: 1px solid #ccc;">209</th>
        <td style="padding: 8px; border: 1px solid #ccc;">Dashboards</td>
        <td style="padding: 8px; border: 1px solid #ccc;">Homepage / Homarr / Homer</td>
      </tr>
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><img src="https://wiki.evageeks.org/images/thumb/a/a0/12_C250_sahaquiel.jpg/175px-12_C250_sahaquiel.jpg" width="64" /></td>
        <td style="padding: 8px; border: 1px solid #ccc;">Sahaquiel</td>
        <th style="padding: 8px; border: 1px solid #ccc;">210</th>
        <td style="padding: 8px; border: 1px solid #ccc;">Monitoring</td>
        <td style="padding: 8px; border: 1px solid #ccc;">Uptimekuma</td>
      </tr>
    </tbody>
  </table>
</div>

[*]: *Future changes or upgrades.*

## 🧪 Testing

- For testing Transmission with OpenVPN add this torrent from [TorGuard](https://torguard.net/checkmytorrentipaddress.php?hash=f1f5bda133bdbb4743773cc8548cbaee1fbff88a).

## 🔗 References

* [Proxmox Packer Templates](https://github.com/sdhibit/packer-proxmox-templates)
* [Terraform Cloud-Init VM](https://github.com/sdhibit/terraform-proxmox-cloud-init-vm)
* [Telmate Terraform Provider](https://github.com/Telmate/terraform-provider-proxmox)
* [Proxmox Ubuntu Templates](https://github.com/bcochofel/packer-proxmox-ubuntu)
* [Proxmox-VM-Disk-and-NFS-Configuration-Guide](https://github.com/Ayman92M/Proxmox-VM-Disk-and-NFS-Configuration-Guide)
* [Evangelion Angel Wiki](https://wiki.evageeks.org/Angels)

---

<div align="center">
  <sub>✦ Inspired by Evangelion. Built for learning, automation, and chaos. ✦</sub>
</div>
