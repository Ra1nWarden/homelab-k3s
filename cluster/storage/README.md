## Restore / Reinstall

```bash
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/

helm repo update

helm upgrade --install nfs-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  -n nfs-provisioner \
  --create-namespace \
  -f cluster/storage/nfs-provisioner-values.yaml
