# Local SSD storage class

A second instance of Rancher's `local-path-provisioner`, configured to provision
PersistentVolumes on each node's local SSD at `/mnt/ssd`. Exposed as the
`local-ssd` StorageClass. Opt-in (cluster default remains `truenas-nfs`).

Use case: stateful workloads (Postgres, MariaDB, Redis, etc.) that benefit
from low-latency local disk. Pods are pinned to whichever node first binds
their PVC; if the node dies, the data is unreachable until it returns.

## Prerequisites: `/mnt/ssd` mount on each node

The provisioner does not create or manage filesystems — it just runs `mkdir`
inside `/mnt/ssd`. Each node must have a writable directory at that path
**before** these manifests are applied.

How `/mnt/ssd` was prepared per node:

- **Nodes with LVM (Ubuntu Server / LVM-installed Ubuntu)**: carved a 40 GB
  logical volume from the existing `ubuntu-vg`, formatted ext4, mounted at
  `/mnt/ssd`, persisted in `/etc/fstab`. Gives a separate filesystem
  boundary — a runaway pod fills `/mnt/ssd`, not `/`.
- **Nodes without LVM (e.g., dual-boot Ubuntu Desktop)**: `mkdir /mnt/ssd`
  on the existing root filesystem. No isolation — pod data shares space
  with `/`. Acceptable for a homelab with disk-usage monitoring; not
  recommended where pods could grow unbounded.

The provisioner is unaware of the difference; both setups work identically
from Kubernetes' perspective.

## Files

### `namespace.yaml`

Creates `local-ssd-storage`. Pure isolation — the provisioner lives here
with its own RBAC and ConfigMap, separate from k3s's built-in
`local-path-storage` namespace.

### `rbac.yaml`

Five resources, two scopes. The provisioner needs both:

- **Cluster-scope** (`ClusterRole` + `ClusterRoleBinding`): watch *all*
  PVCs across the cluster, create/delete PVs (which are cluster-scoped
  resources, not namespaced), see all StorageClasses, look up node names,
  emit events. Controllers always need cluster-wide watch.
- **Namespace-scope** (`Role` + `RoleBinding`): create/delete *helper
  pods* in `local-ssd-storage`. When a PVC needs a directory created on
  node B, the provisioner spawns a helper pod with `nodeName: <node-b>`;
  that helper pod lives in our namespace. Pod-create rights are scoped
  to here, not granted cluster-wide — narrower blast radius.

### `configmap.yaml`

Four keys, all critical:

- **`config.json`** — `nodePathMap` with
  `DEFAULT_PATH_FOR_NON_LISTED_NODES: /mnt/ssd`. Means "every node uses
  `/mnt/ssd` unless listed individually." Since all 3 nodes share the
  same mount path, no per-node entries are needed. To use per-node paths
  (e.g., one node has `/mnt/ssd-fast`), add explicit entries here.
- **`setup`** — shell script run inside the helper pod when a PV is
  created. `mkdir -m 0777 -p "$VOL_DIR"` creates the per-PV directory;
  `0777` is wide-open because pod containers run as arbitrary UIDs (e.g.,
  Postgres runs as UID 999), and figuring out the right ownership per
  app would be brittle. Standard upstream choice — safe because each PV
  directory is only mounted into one pod.
- **`teardown`** — shell script run when a PV is deleted: `rm -rf
  "$VOL_DIR"`. **Rarely runs in our setup** because `reclaimPolicy:
  Retain` means PVC deletion does *not* trigger PV deletion. The script
  is here in case a particular SC is ever flipped to `Delete`.
- **`helperPod.yaml`** — template for the helper pod (used for both
  setup and teardown). `priorityClassName: system-node-critical` keeps
  helper pods from being evicted under pressure. The
  `node.kubernetes.io/disk-pressure: NoSchedule` toleration means
  cleanup can still run on a full node.

### `deployment.yaml`

The provisioner controller pod. Three flags beyond upstream defaults
disambiguate this instance from k3s's built-in:

- **`--provisioner-name rancher.io/local-path-ssd`** — the critical one.
  Without this, our instance would register itself as the default
  `rancher.io/local-path` and *fight with the built-in k3s provisioner*
  over PVC events. With a unique name, only PVCs whose StorageClass
  declares `provisioner: rancher.io/local-path-ssd` come to us.
- **`--configmap-name local-ssd-config`** — tells the provisioner where
  to find its config (renamed from upstream `local-path-config` to keep
  the namespace tidy).
- **`--service-account-name local-ssd-provisioner-sa`** — the
  provisioner stamps this name into the helper pod specs it generates.
  Has to match the SA we actually created.

`replicas: 1` — it's a controller, not a data path. Single replica is
correct. (Don't run two; they'd race for the same PVC events.)

### `storageclass.yaml`

The user-facing object. Four things to note:

- **`provisioner: rancher.io/local-path-ssd`** — must match the
  Deployment's `--provisioner-name` flag exactly, or PVCs land in
  `Pending` forever with no controller picking them up.
- **`volumeBindingMode: WaitForFirstConsumer`** — scheduler picks the
  node first, then the PV is created on that node. Mandatory for local
  storage; the default `Immediate` would bind PVCs at creation time and
  strand pods on the wrong nodes.
- **`reclaimPolicy: Retain`** — deleting a PVC keeps the data on disk
  and marks the PV `Released`. Same as the cluster's `truenas-nfs`
  class. Manual cleanup required.
- **No `storageclass.kubernetes.io/is-default-class: "true"`
  annotation** — opt-in. Default stays on `truenas-nfs` so stateless
  pods don't accidentally land on local storage and get pinned to a
  node.

## Apply

```sh
# Create the namespace first so the namespace-scoped resources don't fail.
kubectl apply -f cluster/storage/local-ssd/namespace.yaml

# Then create everything else (the namespace.yaml apply is a no-op).
kubectl apply -f cluster/storage/local-ssd/
```

`kubectl apply -f <dir>/` processes files in alphabetical order with no
dependency awareness — `configmap.yaml` and `deployment.yaml` are
attempted before `namespace.yaml` and fail outright if the namespace
doesn't already exist. Failed creates do *not* retry. The two-step
apply (namespace first, then everything) avoids the race; alternatively,
running the single `kubectl apply -f cluster/storage/local-ssd/` twice
also works because apply is idempotent.

## Verify

```sh
# Provisioner pod is Running 1/1.
kubectl -n local-ssd-storage get all

# Both storage classes visible; truenas-nfs still default; local-ssd not default.
kubectl get storageclass

# Provisioner logs show successful start, no errors.
kubectl -n local-ssd-storage logs deploy/local-ssd-provisioner | tail -30
```

## Smoke test

After the verify steps pass, prove the path with a real PVC + Pod:

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: local-ssd-smoketest
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-ssd
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: local-ssd-smoketest
  namespace: default
spec:
  containers:
    - name: writer
      image: busybox
      command: ["sh", "-c", "echo hello > /data/hello && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: local-ssd-smoketest
EOF
```

Then:

```sh
# PVC binds only after the pod is scheduled — this is WaitForFirstConsumer.
kubectl get pvc local-ssd-smoketest -w

# Confirm the data on the chosen node.
kubectl get pvc local-ssd-smoketest -o jsonpath='{.spec.volumeName}'   # PV name
kubectl get pv <pv-name> -o jsonpath='{.spec.nodeAffinity}'            # which node
# ssh to that node:
ls /mnt/ssd/

# Cleanup. Note: with reclaimPolicy: Retain the directory on the node is NOT removed.
kubectl delete pod local-ssd-smoketest
kubectl delete pvc local-ssd-smoketest
# On the node, manually remove the leftover directory if you want.
```

## Design notes

### Why a *separate* provisioner instance?

k3s already ships an instance of the same Rancher provisioner under the
`local-path` StorageClass, pointing at `/var/lib/rancher/k3s/storage` (the
boot disk). Editing k3s's bundled config would be reverted on next k3s
upgrade. Running a second instance with different name, path, namespace,
and provisioner string keeps them isolated and upgrade-safe.

### Why `provisioner: rancher.io/local-path-ssd`?

The provisioner name is just a string that must match between the
StorageClass `provisioner` field and the Deployment's `--provisioner-name`
flag — Kubernetes uses it to dispatch PVC events to the right controller.
The `domain/name` format is convention, not requirement.

`rancher.io/local-path-ssd` was chosen because:

1. It's the upstream Rancher image — using the `rancher.io/` prefix
   accurately reflects that.
2. The built-in k3s provisioner uses `rancher.io/local-path`. Adding
   `-ssd` disambiguates so PVCs go to the right instance.
3. It matches what someone googling "local-path-provisioner" would
   expect to see.

Any unique string would technically work (e.g., `homelab/local-ssd`).

### Why `volumeBindingMode: WaitForFirstConsumer`?

With local storage, the PV must live on a specific node. The default
`Immediate` binding would have the scheduler pick a PV at PVC-creation
time, before the pod is scheduled, which strands pods on the wrong node.
`WaitForFirstConsumer` defers PV creation until the scheduler has picked
a node based on pod constraints. Mandatory for any local-storage class.

### Why `reclaimPolicy: Retain`?

`Delete` would have the provisioner `rm -rf` the directory on the node
when the PVC is deleted — irreversible. `Retain` keeps the directory in
place and marks the PV `Released`; we (or a cleanup script) decide when
to remove the data. Matches the cluster's `truenas-nfs` class.

### Why opt-in (not default)?

Local storage pins a pod to its node. Stateless apps that should float
across nodes shouldn't accidentally land on local storage. Keeping
`truenas-nfs` as default means anything that doesn't explicitly request
`local-ssd` gets the safe (mobile) NFS-backed PVC.

### Why uniform across all 3 nodes (no node selector or `allowedTopologies`)?

The same `/mnt/ssd` path exists on every node, so
`DEFAULT_PATH_FOR_NON_LISTED_NODES: /mnt/ssd` in `config.json` covers all
of them with one entry. We do not exclude the control plane: when the
cluster is converted to 3-server etcd HA later, all nodes will run etcd,
and excluding "the control plane" stops being a meaningful concept.

The tradeoff: stateful pod I/O competes with etcd disk I/O on the same
physical SSD. In practice, NVMe SSDs handle the simultaneous load fine
for homelab workloads. Watch `etcd_disk_wal_fsync_duration_seconds` if
you ever wire up Prometheus.

## Sizing and limits

Per-node capacity depends on how `/mnt/ssd` was prepared:

- LVM-carved nodes: limited by the LV size (40 GB by default,
  `lvextend`-able later).
- Bare-directory nodes: shares space with `/`, no hard cap. Watch
  `df -h /` periodically.

To cap per-PVC size, attach a `LimitRange` to namespaces that use
`local-ssd`. Future work; not configured here.
