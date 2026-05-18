# K3s

This directory tracks the K3s cluster configuration.

## Layout

- [`cluster/`](cluster/) - cluster-level configuration, storage, and monitoring.
- [`apps/`](apps/) - application manifests and ingress resources.

## Apply order

1. Storage
2. Ingress
3. Monitoring
4. Namespaces
5. Apps

App deployment and TLS notes live in [apps/README.md](apps/README.md).
Monitoring notes live in [cluster/monitoring/README.md](cluster/monitoring/README.md).
