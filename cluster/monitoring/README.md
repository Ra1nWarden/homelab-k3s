# Monitoring

Monitoring starts with [`prometheus-stack/`](prometheus-stack/), which installs
the core Kubernetes observability platform with `kube-prometheus-stack`:
Prometheus, Prometheus Operator, Alertmanager, Grafana, kube-state-metrics,
node-exporter, dashboards, and alert rules.

## Apply order

1. Storage classes from [`cluster/storage/`](../storage/), especially
   `local-ssd`.
2. Prometheus stack from [`prometheus-stack/`](prometheus-stack/).
3. App-specific `ServiceMonitor` or `PodMonitor` resources later, when an app
   exposes Prometheus metrics.

## Mental model

Prometheus does not magically inspect every machine. It scrapes HTTP endpoints
that expose metrics. Different infrastructure gets metrics into Prometheus in
different ways:

| Target | Usual exporter | Notes |
|---|---|---|
| Kubernetes pods/services | app metrics + `ServiceMonitor` | Best for in-cluster apps. |
| Kubernetes nodes | `node-exporter` from the stack | Installed as a DaemonSet. |
| Kubernetes objects | `kube-state-metrics` from the stack | Reports Deployments, Pods, PVCs, etc. |

## Naming

- Namespace: `monitoring`
- Grafana URL: `https://grafana.apps.home.arpa`
- Prometheus release: `prometheus-stack`

## Later

TrueNAS, Proxmox, VMs, and non-Kubernetes containers can be added after the
basic k3s stack is working. They each need their own exporter or scrape target,
so they are intentionally left out of the first install.
