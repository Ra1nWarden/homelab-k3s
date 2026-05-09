# Storage

Two storage providers configured for the cluster.

## Storage classes

| Class | Default? | Backed by | Use case |
|---|---|---|---|
| `truenas-nfs` | yes | TrueNAS NFS export at `192.168.1.220:/mnt/primary/k3s/pv` | Cluster-wide default. Pods can move between nodes. |
| `local-ssd` | no | Each node's `/mnt/ssd` directory | Opt-in. Pods are pinned to the node where the PV was provisioned. For databases / latency-sensitive stateful workloads. |

## Subdirectories

- [`nfs/`](nfs/) — Helm values + reinstall recipe for `nfs-subdir-external-provisioner`.
- [`local-ssd/`](local-ssd/) — Manifests + design notes for the `local-ssd` storage class (a second instance of `local-path-provisioner`).
