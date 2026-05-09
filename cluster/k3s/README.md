# k3s server config

Source-of-truth copy of `/etc/rancher/k3s/config.yaml` — the file k3s reads
on startup to configure server-side behavior (addon enablement, datastore
choice, advertise IPs, TLS SANs, etc.). Repo is canonical; nodes hold
copies that must be kept in sync.

## Current contents

### `config.yaml`

```yaml
disable:
  - local-storage
```

**Why:** disables k3s's bundled `local-path-provisioner` addon. We use
[`cluster/storage/local-ssd/`](../storage/local-ssd/) as our local
storage class instead — better policy (`Retain`), our own path
(`/mnt/ssd`), no fight with the built-in over default-class status.
Other addons k3s manages here (`traefik`, `servicelb`, `metrics-server`,
`coredns`) remain enabled.

## Apply changes

After editing this file, copy it to each k3s server node and restart k3s:

```sh
# Push to the control plane.
scp cluster/k3s/config.yaml ra1nwarden@192.168.1.223:/tmp/k3s-config.yaml
ssh ra1nwarden@192.168.1.223 \
  'sudo install -m 0644 -o root -g root /tmp/k3s-config.yaml /etc/rancher/k3s/config.yaml \
   && sudo systemctl restart k3s'
```

`install` instead of `mv` so the file lands with the right ownership and
mode regardless of `/tmp/` permissions.

**`systemctl restart k3s` brings the API server down for ~1–2 minutes.**
Workloads on agent nodes keep running; pods on the control plane may get
a brief restart since k3s is the kubelet there too. After restart,
verify:

```sh
ssh ra1nwarden@192.168.1.223 'sudo systemctl status k3s --no-pager | head -10'
kubectl get nodes
kubectl get storageclass
```

## What NOT to put in this file

- **`token:`** (the cluster join token). Sensitive; keep out of git. k3s
  auto-generates one and stores it at
  `/var/lib/rancher/k3s/server/node-token` — outside `config.yaml` —
  so we don't need to set it explicitly.
- **`agent-token:`** (separate token for agent joins, if used). Same
  reasoning.
- **TLS certs / keys.** Reference by path (`tls-key-file:`,
  `tls-cert-file:`) is fine; inline certificate material is not.

## Future: HA with multiple servers

When the cluster converts to 3-server embedded-etcd HA, k3s reads
`/etc/rancher/k3s/config.yaml` *and* merges in any `*.yaml` files under
`/etc/rancher/k3s/config.yaml.d/`. The directory pattern grows naturally:

```
cluster/k3s/
├── config.yaml                 # shared across all servers (this file)
└── config.yaml.d/
    ├── server-control.yaml     # per-node bits (advertise-address, etc.)
    ├── server-worker1.yaml
    └── server-worker2.yaml
```

Each node gets `config.yaml` plus its own `config.yaml.d/` override. Not
needed yet; flagged so the structure can extend without renaming.
