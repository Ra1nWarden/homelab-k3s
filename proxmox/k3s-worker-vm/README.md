# K3s Worker VM on Proxmox

This directory contains native Proxmox automation for creating a VM that joins
the existing k3s cluster as an agent/worker node.

Run these scripts on the Proxmox node as root, not on your Mac.

## Model

The workflow uses Proxmox's native VM template and cloud-init features:

```text
Ubuntu Server cloud image
  -> Proxmox VM template, for example VMID 9001
  -> cloned worker VM, for example VMID 301
  -> cloud-init first boot joins the k3s cluster
```

The VM template is not a file stored in git. It is a Proxmox VM object that has
been converted to a template with `qm template <vmid>`. This repo stores the
scripts, example config, and cloud-init templates needed to create and reuse it.

`qm` is Proxmox's command-line tool for managing QEMU/KVM virtual machines.
For containers, Proxmox uses `pct`; for VMs, it uses `qm`.

## Files

- `k3s-worker.sops.env` - encrypted worker VM config. Edit with SOPS.
- `create-worker-vm.sh` - creates/reuses the VM template and worker VM.
- `cloud-init/user-data.tpl` - first-boot package install, `/mnt/ssd` setup,
  and k3s agent join.
- `cloud-init/meta-data.tpl` - cloud-init instance identity.
- `scripts/render-template.sh` - small placeholder renderer for cloud-init
  snippets.

## Prepare Config With SOPS

Edit the encrypted config from a machine with SOPS and the repo age key:

```sh
sops proxmox/k3s-worker-vm/k3s-worker.sops.env
```

Important values:

```sh
VMID=301
VM_NAME=k3s-worker-01
TEMPLATE_VMID=9001
STORAGE=local-lvm
SNIPPETS_STORAGE=local
BRIDGE=vmbr0
IP_CONFIG=dhcp
SSH_PUBLIC_KEY_FILE=/root/homelab/proxmox/keys/homelab-admin.pub
K3S_URL=https://192.168.1.223:6443
K3S_TOKEN=<redacted>
```

`SNIPPETS_STORAGE` must point at a Proxmox storage with snippet content enabled.
For the usual `local` storage, Proxmox stores snippets under
`/var/lib/vz/snippets`.

The rendered user-data snippet contains the k3s token so the VM can join the
cluster on first boot. The script writes that file with mode `0600`, but you
should still treat the Proxmox snippets storage as sensitive.

Get the k3s join token from the current server:

```sh
ssh ra1nwarden@192.168.1.223 'sudo cat /var/lib/rancher/k3s/server/node-token'
```

Then decrypt to the ignored plaintext env file before running the create script:

```sh
sops decrypt --input-type dotenv --output-type dotenv \
  proxmox/k3s-worker-vm/k3s-worker.sops.env \
  > proxmox/k3s-worker-vm/k3s-worker.env
chmod 600 proxmox/k3s-worker-vm/k3s-worker.env
```

If you decrypt on your Mac and the repo lives on the Proxmox node, copy the
plaintext env file over SSH:

```sh
scp proxmox/k3s-worker-vm/k3s-worker.env \
  root@<proxmox-ip>:/root/homelab/proxmox/k3s-worker-vm/k3s-worker.env
ssh root@<proxmox-ip> 'chmod 600 /root/homelab/proxmox/k3s-worker-vm/k3s-worker.env'
```

Do not commit `k3s-worker.env`; it is ignored by `.gitignore`.

The Proxmox node does not need SOPS if you decrypt on your Mac and copy the
plaintext env file to the node.

## Inspect Without Editing

```sh
sops decrypt --input-type dotenv --output-type dotenv \
  proxmox/k3s-worker-vm/k3s-worker.sops.env
```

## Networking

DHCP:

```sh
IP_CONFIG=dhcp
GATEWAY=
```

Static IP:

```sh
IP_CONFIG=192.168.1.231/24
GATEWAY=192.168.1.1
NAMESERVER=192.168.1.1
SEARCHDOMAIN=home.arpa
```

## Local SSD

The existing `local-ssd` StorageClass expects `/mnt/ssd` on every node.

By default, the script attaches a second virtual disk as `scsi1`, and cloud-init
formats and mounts it at `/mnt/ssd`:

```sh
PREPARE_LOCAL_SSD=1
LOCAL_SSD_SIZE_GB=40
LOCAL_SSD_DEVICE=/dev/sdb
```

Set `LOCAL_SSD_SIZE_GB=0` if you only want cloud-init to create `/mnt/ssd` on
the root filesystem.

## Create the Worker

Run as root on the Proxmox node:

```sh
./create-worker-vm.sh ./k3s-worker.env
```

The script will:

1. Download the configured Ubuntu Server cloud image if it is missing.
2. Create the Proxmox cloud-init VM template if it is missing.
3. Clone the worker VM from the template.
4. Render per-worker cloud-init snippets to the Proxmox snippets storage.
5. Apply CPU, memory, disk, network, SSH, and cloud-init settings.
6. Start the VM.

The script is conservative on reruns. It does not destroy or overwrite an
existing worker VM. If the template exists, it reuses it unless
`REBUILD_TEMPLATE=1`.

## Verify

On the Proxmox node:

```sh
qm status 301
qm guest cmd 301 network-get-interfaces
qm config 301
```

From a machine with cluster access:

```sh
kubectl get nodes -o wide
kubectl describe node k3s-worker-01
```

Inside the VM after it has an IP:

```sh
ssh ubuntu@<worker-ip> 'systemctl status k3s-agent --no-pager'
ssh ubuntu@<worker-ip> 'mount | grep /mnt/ssd || true'
```

## Cleanup

Cleanup is intentionally manual. For a worker that joined the cluster, drain and
delete the Kubernetes node before removing the Proxmox VM:

```sh
kubectl drain k3s-worker-01 --ignore-daemonsets --delete-emptydir-data
kubectl delete node k3s-worker-01
```

Then remove the VM from the Proxmox UI or with `qm destroy` after confirming you
no longer need its disks.
