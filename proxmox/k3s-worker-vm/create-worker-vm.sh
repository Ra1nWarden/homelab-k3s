#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-"$SCRIPT_DIR/k3s-worker.env"}"
RENDER_SCRIPT="$SCRIPT_DIR/scripts/render-template.sh"
USER_DATA_TEMPLATE="$SCRIPT_DIR/cloud-init/user-data.tpl"
META_DATA_TEMPLATE="$SCRIPT_DIR/cloud-init/meta-data.tpl"

usage() {
  cat <<'USAGE'
Usage:
  ./create-worker-vm.sh [path/to/k3s-worker.env]

Run this on the Proxmox node as root. The script creates or reuses an Ubuntu
Server cloud-init VM template, clones a k3s worker VM from it, renders
cloud-init snippets, and starts the VM.
USAGE
}

log() {
  printf '[k3s-worker-vm] %s\n' "$*"
}

warn() {
  printf '[k3s-worker-vm] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[k3s-worker-vm] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run this script as root on the Proxmox node."
}

load_env() {
  [ -f "$ENV_FILE" ] || {
    usage >&2
    die "Env file not found: $ENV_FILE"
  }

  # shellcheck source=/dev/null
  set -a
  source "$ENV_FILE"
  set +a
}

set_defaults() {
  VMID="${VMID:-301}"
  VM_NAME="${VM_NAME:-k3s-worker-01}"
  VM_FQDN="${VM_FQDN:-$VM_NAME}"

  TEMPLATE_VMID="${TEMPLATE_VMID:-9001}"
  TEMPLATE_NAME="${TEMPLATE_NAME:-ubuntu-2404-cloud-k3s-template}"
  REBUILD_TEMPLATE="${REBUILD_TEMPLATE:-0}"

  IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
  IMAGE_FILE="${IMAGE_FILE:-$(basename "$IMAGE_URL")}"
  IMAGE_DOWNLOAD_DIR="${IMAGE_DOWNLOAD_DIR:-/var/lib/vz/template/iso}"
  IMAGE_SHA256="${IMAGE_SHA256:-}"

  STORAGE="${STORAGE:-local-lvm}"
  SNIPPETS_STORAGE="${SNIPPETS_STORAGE:-local}"
  SNIPPETS_DIR="${SNIPPETS_DIR:-}"
  BRIDGE="${BRIDGE:-vmbr0}"
  CORES="${CORES:-2}"
  MEMORY_MB="${MEMORY_MB:-4096}"
  DISK_SIZE_GB="${DISK_SIZE_GB:-40}"
  CI_USER="${CI_USER:-ubuntu}"
  ONBOOT="${ONBOOT:-1}"
  START_VM="${START_VM:-1}"

  IP_CONFIG="${IP_CONFIG:-dhcp}"
  GATEWAY="${GATEWAY:-}"
  NAMESERVER="${NAMESERVER:-}"
  SEARCHDOMAIN="${SEARCHDOMAIN:-}"
  SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"

  K3S_URL="${K3S_URL:-https://192.168.1.223:6443}"
  K3S_TOKEN="${K3S_TOKEN:-}"
  K3S_EXTRA_ARGS="${K3S_EXTRA_ARGS:-}"
  INSTALL_K3S="${INSTALL_K3S:-1}"

  PREPARE_LOCAL_SSD="${PREPARE_LOCAL_SSD:-1}"
  LOCAL_SSD_SIZE_GB="${LOCAL_SSD_SIZE_GB:-40}"
  LOCAL_SSD_DEVICE="${LOCAL_SSD_DEVICE:-/dev/sdb}"
}

validate_number() {
  local name="$1"
  local value="$2"

  case "$value" in
    ''|*[!0-9]*) die "$name must be numeric, got: $value" ;;
  esac
}

validate_env() {
  validate_number VMID "$VMID"
  validate_number TEMPLATE_VMID "$TEMPLATE_VMID"
  validate_number CORES "$CORES"
  validate_number MEMORY_MB "$MEMORY_MB"
  validate_number DISK_SIZE_GB "$DISK_SIZE_GB"
  validate_number ONBOOT "$ONBOOT"
  validate_number START_VM "$START_VM"
  validate_number INSTALL_K3S "$INSTALL_K3S"
  validate_number PREPARE_LOCAL_SSD "$PREPARE_LOCAL_SSD"
  validate_number LOCAL_SSD_SIZE_GB "$LOCAL_SSD_SIZE_GB"

  [ "$VMID" != "$TEMPLATE_VMID" ] || die "VMID and TEMPLATE_VMID must be different."
  [ -f "$RENDER_SCRIPT" ] || die "Missing render script: $RENDER_SCRIPT"
  [ -f "$USER_DATA_TEMPLATE" ] || die "Missing cloud-init template: $USER_DATA_TEMPLATE"
  [ -f "$META_DATA_TEMPLATE" ] || die "Missing cloud-init template: $META_DATA_TEMPLATE"

  if [ "$INSTALL_K3S" = "1" ] && [ -z "$K3S_TOKEN" ]; then
    die "K3S_TOKEN is required when INSTALL_K3S=1. Keep it in the ignored env file or decrypt it from SOPS."
  fi

  if [ -n "$SSH_PUBLIC_KEY_FILE" ] && [ ! -f "$SSH_PUBLIC_KEY_FILE" ]; then
    die "SSH_PUBLIC_KEY_FILE does not exist: $SSH_PUBLIC_KEY_FILE"
  fi

  if [ "$IP_CONFIG" != "dhcp" ] && [ -z "$GATEWAY" ]; then
    warn "IP_CONFIG is static but GATEWAY is empty. The VM may not have a default route."
  fi
}

vm_exists() {
  qm status "$1" >/dev/null 2>&1
}

vm_running() {
  qm status "$1" 2>/dev/null | grep -q 'status: running'
}

vm_is_template() {
  qm config "$1" 2>/dev/null | grep -q '^template: 1$'
}

image_path() {
  printf '%s/%s' "$IMAGE_DOWNLOAD_DIR" "$IMAGE_FILE"
}

ensure_image() {
  local path
  path="$(image_path)"

  mkdir -p "$IMAGE_DOWNLOAD_DIR"

  if [ -f "$path" ]; then
    log "Cloud image already available: $path"
  else
    log "Downloading cloud image from $IMAGE_URL."
    curl -L --fail --output "$path.part" "$IMAGE_URL"
    mv "$path.part" "$path"
  fi

  if [ -n "$IMAGE_SHA256" ]; then
    printf '%s  %s\n' "$IMAGE_SHA256" "$path" | sha256sum -c -
  fi
}

template_unused_disk() {
  qm config "$TEMPLATE_VMID" | awk -F': ' '$1 == "unused0" { print $2; exit }'
}

ensure_template() {
  local imported_disk
  local path

  if vm_exists "$TEMPLATE_VMID"; then
    if ! vm_is_template "$TEMPLATE_VMID"; then
      die "VMID $TEMPLATE_VMID already exists but is not a template. Set a different TEMPLATE_VMID."
    fi

    if [ "$REBUILD_TEMPLATE" = "1" ]; then
      log "REBUILD_TEMPLATE=1; destroying existing template VMID $TEMPLATE_VMID."
      qm destroy "$TEMPLATE_VMID" --purge 1
    else
      log "Template VMID $TEMPLATE_VMID already exists."
      return
    fi
  fi

  path="$(image_path)"
  log "Creating template VMID $TEMPLATE_VMID ($TEMPLATE_NAME)."
  qm create "$TEMPLATE_VMID" \
    --name "$TEMPLATE_NAME" \
    --ostype l26 \
    --machine q35 \
    --cores 2 \
    --memory 2048 \
    --net0 "virtio,bridge=$BRIDGE" \
    --scsihw virtio-scsi-single \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1 \
    --tablet 0

  qm importdisk "$TEMPLATE_VMID" "$path" "$STORAGE"
  imported_disk="$(template_unused_disk)"
  [ -n "$imported_disk" ] || die "Could not find imported disk on VMID $TEMPLATE_VMID."

  qm set "$TEMPLATE_VMID" --scsi0 "$imported_disk",discard=on
  qm set "$TEMPLATE_VMID" --ide2 "$STORAGE:cloudinit"
  qm set "$TEMPLATE_VMID" --boot order=scsi0
  qm set "$TEMPLATE_VMID" --ciuser "$CI_USER"
  qm template "$TEMPLATE_VMID"
}

resolve_snippets_dir() {
  if [ -n "$SNIPPETS_DIR" ]; then
    printf '%s' "$SNIPPETS_DIR"
    return
  fi

  case "$SNIPPETS_STORAGE" in
    local)
      printf '/var/lib/vz/snippets'
      ;;
    *)
      die "Set SNIPPETS_DIR for SNIPPETS_STORAGE=$SNIPPETS_STORAGE. It must point to that storage's snippets directory."
      ;;
  esac
}

shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

render_cloud_init() {
  local snippets_dir
  local user_data_file
  local meta_data_file

  snippets_dir="$(resolve_snippets_dir)"
  mkdir -p "$snippets_dir"

  user_data_file="$snippets_dir/${VM_NAME}-user-data.yaml"
  meta_data_file="$snippets_dir/${VM_NAME}-meta-data.yaml"

  export VM_NAME
  export VM_FQDN
  export CLOUDINIT_PREPARE_LOCAL_SSD
  export CLOUDINIT_LOCAL_SSD_DEVICE
  export CLOUDINIT_INSTALL_K3S
  export CLOUDINIT_K3S_URL
  export CLOUDINIT_K3S_TOKEN
  export CLOUDINIT_K3S_EXTRA_ARGS

  CLOUDINIT_PREPARE_LOCAL_SSD="$(shell_quote "$PREPARE_LOCAL_SSD")"
  CLOUDINIT_LOCAL_SSD_DEVICE="$(shell_quote "$LOCAL_SSD_DEVICE")"
  CLOUDINIT_INSTALL_K3S="$(shell_quote "$INSTALL_K3S")"
  CLOUDINIT_K3S_URL="$(shell_quote "$K3S_URL")"
  CLOUDINIT_K3S_TOKEN="$(shell_quote "$K3S_TOKEN")"
  CLOUDINIT_K3S_EXTRA_ARGS="$(shell_quote "$K3S_EXTRA_ARGS")"

  log "Rendering cloud-init snippets to $snippets_dir."
  "$RENDER_SCRIPT" "$USER_DATA_TEMPLATE" "$user_data_file"
  "$RENDER_SCRIPT" "$META_DATA_TEMPLATE" "$meta_data_file"
  chmod 600 "$user_data_file"
  chmod 644 "$meta_data_file"

  qm set "$VMID" --cicustom "user=$SNIPPETS_STORAGE:snippets/$(basename "$user_data_file"),meta=$SNIPPETS_STORAGE:snippets/$(basename "$meta_data_file")"
}

ipconfig0_value() {
  local value
  value="ip=$IP_CONFIG"

  if [ -n "$GATEWAY" ]; then
    value="$value,gw=$GATEWAY"
  fi

  printf '%s' "$value"
}

set_optional_cloud_init_values() {
  if [ -n "$SSH_PUBLIC_KEY_FILE" ]; then
    qm set "$VMID" --sshkey "$SSH_PUBLIC_KEY_FILE"
  fi

  if [ -n "$NAMESERVER" ]; then
    qm set "$VMID" --nameserver "$NAMESERVER"
  fi

  if [ -n "$SEARCHDOMAIN" ]; then
    qm set "$VMID" --searchdomain "$SEARCHDOMAIN"
  fi
}

disk_attached() {
  local disk="$1"
  qm config "$VMID" | grep -q "^$disk:"
}

create_or_update_worker() {
  if vm_exists "$VMID"; then
    vm_is_template "$VMID" && die "VMID $VMID is a template. Choose a different worker VMID."
    log "Worker VMID $VMID already exists; applying non-destructive settings."
  else
    log "Cloning worker VMID $VMID ($VM_NAME) from template $TEMPLATE_VMID."
    qm clone "$TEMPLATE_VMID" "$VMID" --name "$VM_NAME" --full 1 --storage "$STORAGE"
    qm resize "$VMID" scsi0 "${DISK_SIZE_GB}G"
  fi

  qm set "$VMID" \
    --name "$VM_NAME" \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --agent enabled=1 \
    --onboot "$ONBOOT" \
    --net0 "virtio,bridge=$BRIDGE" \
    --ipconfig0 "$(ipconfig0_value)" \
    --ciuser "$CI_USER" \
    --boot order=scsi0

  set_optional_cloud_init_values

  if [ "$PREPARE_LOCAL_SSD" = "1" ] && [ "$LOCAL_SSD_SIZE_GB" -gt 0 ]; then
    if disk_attached scsi1; then
      log "scsi1 already exists on VMID $VMID; leaving local SSD disk unchanged."
    else
      log "Adding ${LOCAL_SSD_SIZE_GB}G local SSD disk as scsi1."
      qm set "$VMID" --scsi1 "$STORAGE:$LOCAL_SSD_SIZE_GB",discard=on
    fi
  fi

  render_cloud_init
}

start_worker() {
  if [ "$START_VM" != "1" ]; then
    log "START_VM is not 1; leaving VMID $VMID stopped."
    return
  fi

  if vm_running "$VMID"; then
    log "Worker VMID $VMID is already running."
    return
  fi

  log "Starting worker VMID $VMID."
  qm start "$VMID"
}

print_next_steps() {
  cat <<EOF

K3s worker VM provisioning finished.

Verify on the Proxmox node:
  qm status $VMID
  qm guest cmd $VMID network-get-interfaces

Verify from a machine with kubectl access:
  kubectl get nodes -o wide
  kubectl describe node $VM_NAME

Verify inside the VM after it has an IP:
  ssh $CI_USER@<worker-ip> 'systemctl status k3s-agent --no-pager'
EOF
}

main() {
  require_root
  require_command awk
  require_command curl
  require_command grep
  require_command chmod
  require_command mkdir
  require_command mv
  require_command perl
  require_command qm
  require_command sed
  require_command sha256sum

  load_env
  set_defaults
  validate_env
  ensure_image
  ensure_template
  create_or_update_worker
  start_worker
  print_next_steps
}

main "$@"
