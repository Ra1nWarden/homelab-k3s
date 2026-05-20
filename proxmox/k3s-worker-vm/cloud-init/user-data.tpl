#cloud-config
hostname: @VM_NAME@
fqdn: @VM_FQDN@
manage_etc_hosts: true
package_update: true
package_upgrade: false
packages:
  - ca-certificates
  - curl
  - e2fsprogs
  - nfs-common
  - open-iscsi
  - qemu-guest-agent

write_files:
  - path: /usr/local/sbin/k3s-worker-firstboot.sh
    owner: root:root
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      log() {
        printf '[k3s-worker-firstboot] %s\n' "$*"
      }

      PREPARE_LOCAL_SSD=@CLOUDINIT_PREPARE_LOCAL_SSD@
      LOCAL_SSD_DEVICE=@CLOUDINIT_LOCAL_SSD_DEVICE@
      INSTALL_K3S=@CLOUDINIT_INSTALL_K3S@
      K3S_URL=@CLOUDINIT_K3S_URL@
      K3S_TOKEN=@CLOUDINIT_K3S_TOKEN@
      K3S_EXTRA_ARGS=@CLOUDINIT_K3S_EXTRA_ARGS@

      systemctl enable --now qemu-guest-agent

      if [ "$PREPARE_LOCAL_SSD" = "1" ]; then
        mkdir -p /mnt/ssd

        if [ -n "$LOCAL_SSD_DEVICE" ] && [ -b "$LOCAL_SSD_DEVICE" ]; then
          if ! blkid "$LOCAL_SSD_DEVICE" >/dev/null 2>&1; then
            log "Formatting $LOCAL_SSD_DEVICE for /mnt/ssd."
            mkfs.ext4 -F "$LOCAL_SSD_DEVICE"
          fi

          ssd_uuid="$(blkid -s UUID -o value "$LOCAL_SSD_DEVICE")"
          if ! grep -q "UUID=$ssd_uuid[[:space:]]/mnt/ssd" /etc/fstab; then
            printf 'UUID=%s /mnt/ssd ext4 defaults,nofail 0 2\n' "$ssd_uuid" >> /etc/fstab
          fi

          if ! mountpoint -q /mnt/ssd; then
            mount /mnt/ssd
          fi
        fi

        chmod 0777 /mnt/ssd
      fi

      if [ "$INSTALL_K3S" != "1" ]; then
        log "INSTALL_K3S is not 1; skipping k3s agent install."
        exit 0
      fi

      if systemctl is-active --quiet k3s-agent 2>/dev/null; then
        log "k3s-agent is already running."
        exit 0
      fi

      if [ -z "$K3S_URL" ] || [ -z "$K3S_TOKEN" ]; then
        log "K3S_URL and K3S_TOKEN are required to join the cluster."
        exit 1
      fi

      log "Installing k3s agent and joining $K3S_URL."
      curl -sfL https://get.k3s.io | \
        INSTALL_K3S_EXEC="agent $K3S_EXTRA_ARGS" \
        K3S_URL="$K3S_URL" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -

runcmd:
  - [ /usr/local/sbin/k3s-worker-firstboot.sh ]
