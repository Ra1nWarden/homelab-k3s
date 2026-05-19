#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-"$SCRIPT_DIR/openclaw-lxc.env"}"
INSTALL_SCRIPT="$SCRIPT_DIR/install-openclaw.sh"

usage() {
  cat <<'USAGE'
Usage:
  ./create-lxc.sh [path/to/openclaw-lxc.env]

Run this on the Proxmox node as root. The script creates or updates an
unprivileged LXC, copies install-openclaw.sh into it, and runs the native
OpenClaw installer inside the container.
USAGE
}

log() {
  printf '[openclaw-lxc] %s\n' "$*"
}

die() {
  printf '[openclaw-lxc] ERROR: %s\n' "$*" >&2
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
  CTID="${CTID:-240}"
  HOSTNAME="${HOSTNAME:-openclaw}"
  TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
  TEMPLATE="${TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
  ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"
  ROOTFS_SIZE_GB="${ROOTFS_SIZE_GB:-32}"
  MEMORY_MB="${MEMORY_MB:-4096}"
  SWAP_MB="${SWAP_MB:-1024}"
  CORES="${CORES:-2}"
  BRIDGE="${BRIDGE:-vmbr0}"
  IP_CONFIG="${IP_CONFIG:-dhcp}"
  GATEWAY="${GATEWAY:-}"
  SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"

  OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
  OPENCLAW_PREFIX="${OPENCLAW_PREFIX:-/home/$OPENCLAW_USER/.openclaw}"
  OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
  OPENCLAW_INSTALL_METHOD="${OPENCLAW_INSTALL_METHOD:-npm}"
  OPENCLAW_NO_ONBOARD="${OPENCLAW_NO_ONBOARD:-1}"
}

validate_env() {
  case "$CTID" in
    ''|*[!0-9]*) die "CTID must be numeric, got: $CTID" ;;
  esac

  [ -f "$INSTALL_SCRIPT" ] || die "Missing install script: $INSTALL_SCRIPT"

  if [ -n "$SSH_PUBLIC_KEY_FILE" ] && [ ! -f "$SSH_PUBLIC_KEY_FILE" ]; then
    die "SSH_PUBLIC_KEY_FILE does not exist: $SSH_PUBLIC_KEY_FILE"
  fi
}

template_volid() {
  printf '%s:vztmpl/%s' "$TEMPLATE_STORAGE" "$TEMPLATE"
}

ensure_template() {
  local volid
  volid="$(template_volid)"

  if pvesm path "$volid" >/dev/null 2>&1; then
    log "Template already available: $volid"
    return
  fi

  log "Template not found, updating template index."
  pveam update
  log "Downloading template $TEMPLATE to $TEMPLATE_STORAGE."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
}

container_exists() {
  pct status "$CTID" >/dev/null 2>&1
}

container_running() {
  pct status "$CTID" 2>/dev/null | grep -q 'status: running'
}

net0_config() {
  local value
  value="name=eth0,bridge=$BRIDGE,ip=$IP_CONFIG"

  if [ -n "$GATEWAY" ]; then
    value="$value,gw=$GATEWAY"
  fi

  printf '%s' "$value"
}

create_container() {
  local volid
  local net0
  local args

  volid="$(template_volid)"
  net0="$(net0_config)"

  args=(
    "$CTID"
    "$volid"
    --hostname "$HOSTNAME"
    --unprivileged 1
    --cores "$CORES"
    --memory "$MEMORY_MB"
    --swap "$SWAP_MB"
    --rootfs "$ROOTFS_STORAGE:$ROOTFS_SIZE_GB"
    --net0 "$net0"
    --onboot 1
    --start 1
  )

  if [ -n "$SSH_PUBLIC_KEY_FILE" ]; then
    args+=(--ssh-public-keys "$SSH_PUBLIC_KEY_FILE")
  fi

  log "Creating LXC $CTID ($HOSTNAME)."
  pct create "${args[@]}"
}

update_container_settings() {
  log "LXC $CTID already exists; applying non-destructive settings."
  pct set "$CTID" --onboot 1
  pct set "$CTID" --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
}

start_container() {
  if container_running; then
    log "LXC $CTID is already running."
    return
  fi

  log "Starting LXC $CTID."
  pct start "$CTID"
}

wait_for_container_exec() {
  local attempts
  attempts=60

  log "Waiting for LXC $CTID to accept commands."
  while [ "$attempts" -gt 0 ]; do
    if pct exec "$CTID" -- true >/dev/null 2>&1; then
      return
    fi

    attempts=$((attempts - 1))
    sleep 2
  done

  die "Timed out waiting for LXC $CTID to accept commands."
}

install_openclaw() {
  log "Copying installer into LXC $CTID."
  pct push "$CTID" "$INSTALL_SCRIPT" /root/install-openclaw.sh --perms 0755

  log "Running native OpenClaw installer inside LXC $CTID."
  pct exec "$CTID" -- env \
    OPENCLAW_USER="$OPENCLAW_USER" \
    OPENCLAW_PREFIX="$OPENCLAW_PREFIX" \
    OPENCLAW_VERSION="$OPENCLAW_VERSION" \
    OPENCLAW_INSTALL_METHOD="$OPENCLAW_INSTALL_METHOD" \
    OPENCLAW_NO_ONBOARD="$OPENCLAW_NO_ONBOARD" \
    bash /root/install-openclaw.sh
}

print_next_steps() {
  cat <<EOF

OpenClaw LXC setup finished.

Next steps:
  pct enter $CTID
  sudo -iu $OPENCLAW_USER
  openclaw onboard --install-daemon
  openclaw status

If you used DHCP, find the container IP with:
  pct exec $CTID -- ip -4 addr show eth0
EOF
}

main() {
  require_root
  require_command pct
  require_command pveam
  require_command pvesm
  load_env
  set_defaults
  validate_env
  ensure_template

  if container_exists; then
    update_container_settings
  else
    create_container
  fi

  start_container
  wait_for_container_exec
  install_openclaw
  print_next_steps
}

main "$@"
