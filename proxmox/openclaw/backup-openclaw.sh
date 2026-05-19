#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-"$SCRIPT_DIR/openclaw-lxc.env"}"

usage() {
  cat <<'USAGE'
Usage:
  ./backup-openclaw.sh [path/to/openclaw-lxc.env]

Run this on the Proxmox node as root. The script creates a verified OpenClaw
application backup inside the LXC, pulls it to the configured host directory,
and optionally runs vzdump for a whole-container backup.
USAGE
}

log() {
  printf '[openclaw-backup] %s\n' "$*"
}

die() {
  printf '[openclaw-backup] ERROR: %s\n' "$*" >&2
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
  OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
  OPENCLAW_PREFIX="${OPENCLAW_PREFIX:-/home/$OPENCLAW_USER/.openclaw}"
  OPENCLAW_BACKUP_HOST_DIR="${OPENCLAW_BACKUP_HOST_DIR:-/mnt/pve/truenas-openclaw}"
  OPENCLAW_BACKUP_INCLUDE_WORKSPACE="${OPENCLAW_BACKUP_INCLUDE_WORKSPACE:-0}"
  PROXMOX_BACKUP_STORAGE="${PROXMOX_BACKUP_STORAGE:-truenas-backups}"
  PROXMOX_BACKUP_MODE="${PROXMOX_BACKUP_MODE:-snapshot}"
  PROXMOX_BACKUP_COMPRESS="${PROXMOX_BACKUP_COMPRESS:-zstd}"
  PROXMOX_RUN_VZDUMP="${PROXMOX_RUN_VZDUMP:-0}"
}

validate_env() {
  case "$CTID" in
    ''|*[!0-9]*) die "CTID must be numeric, got: $CTID" ;;
  esac

  pct status "$CTID" >/dev/null 2>&1 || die "LXC $CTID does not exist."
}

container_running() {
  pct status "$CTID" 2>/dev/null | grep -q 'status: running'
}

ensure_running() {
  if container_running; then
    return
  fi

  log "Starting LXC $CTID for backup."
  pct start "$CTID"
}

backup_args() {
  if [ "$OPENCLAW_BACKUP_INCLUDE_WORKSPACE" = "1" ]; then
    printf '%s' ''
  else
    printf '%s' '--no-include-workspace'
  fi
}

create_app_backup() {
  local extra_args
  extra_args="$(backup_args)"

  log "Creating OpenClaw application backup inside LXC $CTID."
  pct exec "$CTID" -- install -d -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" /tmp/openclaw-backups
  pct exec "$CTID" -- sudo -iu "$OPENCLAW_USER" env \
    PATH="$OPENCLAW_PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    OPENCLAW_HOME="/home/$OPENCLAW_USER" \
    OPENCLAW_STATE_DIR="$OPENCLAW_PREFIX" \
    bash -lc "openclaw backup create --output /tmp/openclaw-backups --verify $extra_args"
}

latest_container_backup_path() {
  pct exec "$CTID" -- bash -lc "ls -1t /tmp/openclaw-backups/*.tar.gz 2>/dev/null | head -n 1"
}

pull_app_backup() {
  local container_path
  local archive_name
  local host_path

  container_path="$(latest_container_backup_path)"
  [ -n "$container_path" ] || die "No OpenClaw backup archive found in /tmp/openclaw-backups."

  archive_name="$(basename "$container_path")"
  host_path="$OPENCLAW_BACKUP_HOST_DIR/$archive_name"

  log "Ensuring host backup directory exists: $OPENCLAW_BACKUP_HOST_DIR"
  mkdir -p "$OPENCLAW_BACKUP_HOST_DIR"

  log "Pulling $archive_name to $OPENCLAW_BACKUP_HOST_DIR."
  pct pull "$CTID" "$container_path" "$host_path"

  log "Verifying backup archive inside the LXC."
  pct exec "$CTID" -- sudo -iu "$OPENCLAW_USER" env \
    PATH="$OPENCLAW_PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    OPENCLAW_HOME="/home/$OPENCLAW_USER" \
    OPENCLAW_STATE_DIR="$OPENCLAW_PREFIX" \
    bash -lc "openclaw backup verify '$container_path'"

  log "Backup saved: $host_path"
}

run_vzdump_if_enabled() {
  if [ "$PROXMOX_RUN_VZDUMP" != "1" ]; then
    log "Skipping vzdump; set PROXMOX_RUN_VZDUMP=1 to enable whole-container backups."
    return
  fi

  require_command vzdump
  log "Running vzdump for LXC $CTID to storage $PROXMOX_BACKUP_STORAGE."
  vzdump "$CTID" \
    --storage "$PROXMOX_BACKUP_STORAGE" \
    --mode "$PROXMOX_BACKUP_MODE" \
    --compress "$PROXMOX_BACKUP_COMPRESS"
}

main() {
  require_root
  require_command pct
  load_env
  set_defaults
  validate_env
  ensure_running
  create_app_backup
  pull_app_backup
  run_vzdump_if_enabled
}

main "$@"
