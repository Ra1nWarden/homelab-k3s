# Homelab

This repo tracks homelab infrastructure configuration. The root is organized by
platform so Kubernetes/K3s and Proxmox code can evolve independently.

## Layout

- [`k3s/`](k3s/) - K3s cluster configuration, storage, monitoring, and app
  manifests.
- [`proxmox/`](proxmox/) - Proxmox infrastructure code and notes.

## Current infrastructure

### K3s

- Control node: 192.168.1.223
- TrueNAS backend: 192.168.1.220
- Storage: TrueNAS NFS via nfs-subdir-external-provisioner
- Default app storage class: nfs-client

Apply order:

1. Storage
2. Ingress
3. Monitoring
4. Namespaces
5. Apps

K3s deployment and TLS notes live in [k3s/README.md](k3s/README.md).
