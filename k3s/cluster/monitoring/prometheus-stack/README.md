# Prometheus stack

This installs the Prometheus Community `kube-prometheus-stack` Helm chart.

The chart is the standard batteries-included Kubernetes monitoring stack:

- **Prometheus Operator** manages Prometheus, Alertmanager, alert rules, and
  scrape resources as Kubernetes CRDs.
- **Prometheus** stores time-series metrics and runs alert/query rules.
- **Alertmanager** receives alerts from Prometheus and routes notifications.
- **Grafana** provides dashboards.
- **kube-state-metrics** exposes Kubernetes object state.
- **node-exporter** exposes Linux node CPU, memory, disk, and network metrics.

## Storage choices

Prometheus and Alertmanager use `local-ssd` because Prometheus TSDB expects a
local filesystem with reliable locking and low latency. This pins each PVC to
the node that first schedules the pod. For a learning homelab, that is a good
tradeoff: fast and simple, but not highly available.

Grafana uses `truenas-nfs` because its state is small and less write-heavy.
Dashboards should still be exported or managed as ConfigMaps over time.

## Create the Grafana admin secret

Do not commit the Grafana password. Create it directly in the cluster:

```sh
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<choose-a-password>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Install / upgrade

```sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --version 85.0.1 \
  -n monitoring \
  --create-namespace \
  -f k3s/cluster/monitoring/prometheus-stack/values.yaml
```

## TLS for Grafana

Grafana uses the same wildcard TLS pattern as apps:

```sh
kubectl -n monitoring create secret tls apps-home-arpa-tls \
  --cert=k3s/apps/apps.home.arpa.crt \
  --key=k3s/apps/apps.home.arpa.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

Then browse to:

```text
https://grafana.apps.home.arpa
```

## Verify

```sh
kubectl -n monitoring get pods
kubectl -n monitoring get prometheus,alertmanager,servicemonitor,podmonitor
kubectl -n monitoring get pvc
```

If Grafana DNS/TLS is not ready yet, port-forward instead:

```sh
kubectl -n monitoring port-forward svc/prometheus-stack-grafana 3000:80
```

Then open:

```text
http://127.0.0.1:3000
```

## k3s-specific notes

This values file disables several default scrape targets that commonly create
false alerts on k3s:

- `kubeEtcd` is disabled because this cluster is not using exposed etcd metrics.
- `kubeControllerManager` and `kubeScheduler` are disabled because k3s runs
  them inside the server process and does not expose the usual component
  endpoints.
- `kubeProxy` is disabled because k3s networking often does not expose it as a
  separate scrapeable component.

Kubelet, node-exporter, CoreDNS, and Kubernetes object metrics remain enabled.

## Learning path

After install, start with these Grafana dashboards:

1. Kubernetes / Compute Resources / Namespace
2. Kubernetes / Compute Resources / Node
3. Node Exporter / Nodes
4. Kubernetes / Persistent Volumes

In Prometheus, try these queries:

```promql
up
node_filesystem_avail_bytes
container_cpu_usage_seconds_total
kube_pod_container_status_restarts_total
```
