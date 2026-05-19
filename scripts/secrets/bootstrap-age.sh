#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[sops-age] %s\n' "$*"
}

die() {
  printf '[sops-age] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

default_key_file() {
  if [ -n "${SOPS_AGE_KEY_FILE:-}" ]; then
    printf '%s\n' "$SOPS_AGE_KEY_FILE"
    return
  fi

  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "$HOME/Library/Application Support/sops/age/keys.txt"
      ;;
    Linux)
      printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
      ;;
    *)
      die "Unsupported OS. Set SOPS_AGE_KEY_FILE to the desired keys.txt path."
      ;;
  esac
}

main() {
  local key_file
  local key_dir

  require_command age-keygen

  key_file="$(default_key_file)"
  key_dir="$(dirname "$key_file")"

  mkdir -p "$key_dir"

  if [ -s "$key_file" ]; then
    log "Using existing age identity: $key_file"
  else
    log "Creating age identity: $key_file"
    age-keygen -o "$key_file"
    chmod 600 "$key_file"
  fi

  log "Public recipient:"
  age-keygen -y "$key_file"

  cat <<EOF

Back up the private identity outside git. If using 1Password, store the contents
of this file in a concealed field:

  $key_file

Never commit that file or any value beginning with AGE-SECRET-KEY-.
EOF
}

main "$@"
