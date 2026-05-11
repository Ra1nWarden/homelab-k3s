# Homelab k3s

This repo tracks my k3s cluster configuration.

## Cluster

- k3s control node: 192.168.1.223
- TrueNAS backend: 192.168.1.220
- Storage: TrueNAS NFS via nfs-subdir-external-provisioner
- Default app storage class: nfs-client

## Apply order

1. Storage
2. Ingress
3. Namespaces
4. Apps

App deployment and TLS notes live in [apps/README.md](apps/README.md).
