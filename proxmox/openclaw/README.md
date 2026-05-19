# OpenClaw on Proxmox LXC

This directory contains scripts for deploying OpenClaw directly inside an
unprivileged Proxmox LXC container. It does not install Docker inside the LXC.

Run the host-side scripts on the Proxmox node, not on your Mac.

## Files

- `openclaw-lxc.env.example` - copy to `openclaw-lxc.env` and edit locally.
- `create-lxc.sh` - creates/updates the LXC and runs the OpenClaw installer.
- `install-openclaw.sh` - runs inside the LXC as root.
- `backup-openclaw.sh` - creates OpenClaw app backups and optionally runs `vzdump`.

## Storage Model

Recommended storage for this host:

```text
local
  LXC templates
  ISO images
  snippets

local-lvm
  LXC root disks
  VM disks

TrueNAS NFS storage
  Proxmox vzdump backups
  OpenClaw app-level backup archives
```

For OpenClaw, keep the live LXC root disk on `local-lvm` and use TrueNAS for
backups.

## Prepare Config

For local plaintext config, on the Proxmox node clone or copy this repo, then:

```sh
cd proxmox/openclaw
cp openclaw-lxc.env.example openclaw-lxc.env
vi openclaw-lxc.env
```

Important values:

```sh
CTID=240
TEMPLATE_STORAGE=local
ROOTFS_STORAGE=local-lvm
ROOTFS_SIZE_GB=32
IP_CONFIG=dhcp
PROXMOX_BACKUP_STORAGE=truenas-backups
OPENCLAW_BACKUP_HOST_DIR=/mnt/pve/truenas-openclaw
```

If you use SOPS, edit the encrypted env file directly from the repo root:

```sh
sops proxmox/openclaw/openclaw-lxc.sops.env
```

Then decrypt locally and stream the plaintext env file to Proxmox:

```sh
sops decrypt proxmox/openclaw/openclaw-lxc.sops.env \
  | ssh root@<proxmox-ip> 'cat > /root/homelab/proxmox/openclaw/openclaw-lxc.env && chmod 600 /root/homelab/proxmox/openclaw/openclaw-lxc.env'
```

See `docs/secrets.md` for the full SOPS/age workflow.

If you want a static IP, use:

```sh
IP_CONFIG=192.168.1.240/24
GATEWAY=192.168.1.1
```

## Download LXC Template

The create script can download the configured template. You can also do it
manually first:

```sh
pveam update
pveam available --section system | grep debian-12
pveam download local debian-12-standard_12.7-1_amd64.tar.zst
```

If Proxmox lists a newer Debian 12 template, update `TEMPLATE` in
`openclaw-lxc.env`.

## Create the LXC and Install OpenClaw

Run as root on the Proxmox node:

```sh
./create-lxc.sh ./openclaw-lxc.env
```

The script will:

1. Create an unprivileged LXC if the CTID does not exist.
2. Start the LXC.
3. Copy `install-openclaw.sh` into the container.
4. Create a dedicated `openclaw` user inside the container.
5. Install OpenClaw into `/home/openclaw/.openclaw`.

It does not automate OpenClaw provider authentication.

## Complete Onboarding

After the script finishes:

```sh
pct enter 240
sudo -iu openclaw
openclaw onboard --install-daemon
openclaw status
openclaw dashboard
```

If you used DHCP, find the LXC address:

```sh
pct exec 240 -- ip -4 addr show eth0
```

Keep the dashboard LAN-only or VPN-only until you deliberately place it behind
auth and a reverse proxy.

## Application Backups

OpenClaw state is more than one config file. Preserve the full state directory:

```text
/home/openclaw/.openclaw/
```

That state can include auth profiles, provider credentials, channel sessions,
and other sensitive data. Protect the TrueNAS dataset accordingly.

Create a verified app-level backup and pull it to the configured TrueNAS-backed
host directory:

```sh
./backup-openclaw.sh ./openclaw-lxc.env
```

By default, the script excludes workspace data:

```sh
OPENCLAW_BACKUP_INCLUDE_WORKSPACE=0
```

Set this to `1` if OpenClaw-managed workspaces must be included in the app
archive.

## Whole-Container Backups

Proxmox `vzdump` gives you full LXC recovery. To have `backup-openclaw.sh` run
`vzdump` after the app backup, set:

```sh
PROXMOX_RUN_VZDUMP=1
PROXMOX_BACKUP_STORAGE=truenas-backups
PROXMOX_BACKUP_MODE=snapshot
PROXMOX_BACKUP_COMPRESS=zstd
```

Manual equivalent:

```sh
vzdump 240 --storage truenas-backups --mode snapshot --compress zstd
```

Use `snapshot` mode when the root disk storage supports snapshots. Use `stop`
mode if you prefer the most conservative backup consistency and can tolerate
downtime.

## Snapshots

Use snapshots before risky upgrades or configuration changes:

```sh
pct snapshot 240 before-openclaw-upgrade
pct listsnapshot 240
pct rollback 240 before-openclaw-upgrade
```

Snapshots are rollback points, not disaster recovery. Keep TrueNAS-backed
backups for host or NVMe failure.

## Restore

Full LXC restore:

```sh
pct restore 240 /mnt/pve/truenas-backups/dump/vzdump-lxc-240-<timestamp>.tar.zst
pct start 240
pct exec 240 -- sudo -iu openclaw openclaw doctor
pct exec 240 -- sudo -iu openclaw openclaw status
```

Fresh LXC plus app-level restore:

1. Run `create-lxc.sh`.
2. Stop the OpenClaw gateway as the `openclaw` user.
3. Restore the latest OpenClaw backup into `/home/openclaw/.openclaw`.
4. Fix ownership:

```sh
pct exec 240 -- chown -R openclaw:openclaw /home/openclaw/.openclaw
pct exec 240 -- sudo -iu openclaw openclaw doctor
pct exec 240 -- sudo -iu openclaw openclaw gateway restart
pct exec 240 -- sudo -iu openclaw openclaw status
```

## Troubleshooting

Check container status:

```sh
pct status 240
pct enter 240
```

Check OpenClaw as the service user:

```sh
sudo -iu openclaw
openclaw --version
openclaw doctor
openclaw status
```

Check Proxmox NFS storage:

```sh
pvesm status
ls -la /mnt/pve/truenas-backups
ls -la /mnt/pve/truenas-openclaw
```

If NFS writes fail, fix permissions on the TrueNAS dataset/export before running
backups.
