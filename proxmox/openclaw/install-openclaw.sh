#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[openclaw-install] %s\n' "$*"
}

die() {
  printf '[openclaw-install] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run this script as root inside the LXC."
}

set_defaults() {
  OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
  OPENCLAW_PREFIX="${OPENCLAW_PREFIX:-/home/$OPENCLAW_USER/.openclaw}"
  OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
  OPENCLAW_INSTALL_METHOD="${OPENCLAW_INSTALL_METHOD:-npm}"
  OPENCLAW_NO_ONBOARD="${OPENCLAW_NO_ONBOARD:-1}"
  OPENCLAW_HOME="/home/$OPENCLAW_USER"
}

install_packages() {
  log "Installing base packages."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl git jq sudo
}

ensure_user() {
  if id "$OPENCLAW_USER" >/dev/null 2>&1; then
    log "User already exists: $OPENCLAW_USER"
  else
    log "Creating service user: $OPENCLAW_USER"
    adduser --disabled-password --gecos "" "$OPENCLAW_USER"
  fi

  install -d -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" "$OPENCLAW_HOME"
}

enable_linger() {
  if command -v loginctl >/dev/null 2>&1; then
    log "Enabling lingering for user services."
    loginctl enable-linger "$OPENCLAW_USER" || log "Could not enable lingering; run 'loginctl enable-linger $OPENCLAW_USER' after systemd is ready."
  else
    log "loginctl is unavailable; skipping linger setup."
  fi
}

write_profile() {
  local profile_file
  profile_file="$OPENCLAW_HOME/.profile.d-openclaw"

  log "Writing OpenClaw shell profile snippet."
  cat >"$profile_file" <<EOF
export PATH="$OPENCLAW_PREFIX/bin:\$PATH"
export OPENCLAW_HOME="$OPENCLAW_HOME"
export OPENCLAW_STATE_DIR="$OPENCLAW_PREFIX"
EOF
  chown "$OPENCLAW_USER:$OPENCLAW_USER" "$profile_file"
  chmod 0644 "$profile_file"

  touch "$OPENCLAW_HOME/.profile"

  if ! grep -qF '. "$HOME/.profile.d-openclaw"' "$OPENCLAW_HOME/.profile"; then
    cat >>"$OPENCLAW_HOME/.profile" <<'EOF'

if [ -f "$HOME/.profile.d-openclaw" ]; then
  . "$HOME/.profile.d-openclaw"
fi
EOF
  fi

  chown "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_HOME/.profile"
}

install_openclaw() {
  local install_args

  install -d -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" "$OPENCLAW_PREFIX"

  install_args=(--prefix "$OPENCLAW_PREFIX")

  if [ -n "$OPENCLAW_VERSION" ] && [ "$OPENCLAW_VERSION" != "latest" ]; then
    install_args+=(--version "$OPENCLAW_VERSION")
  fi

  if [ "$OPENCLAW_NO_ONBOARD" = "1" ]; then
    install_args+=(--no-onboard)
  fi

  log "Installing OpenClaw into $OPENCLAW_PREFIX."
  sudo -iu "$OPENCLAW_USER" env \
    OPENCLAW_VERSION="$OPENCLAW_VERSION" \
    OPENCLAW_INSTALL_METHOD="$OPENCLAW_INSTALL_METHOD" \
    OPENCLAW_NO_ONBOARD="$OPENCLAW_NO_ONBOARD" \
    OPENCLAW_HOME="$OPENCLAW_HOME" \
    OPENCLAW_STATE_DIR="$OPENCLAW_PREFIX" \
    bash -lc "$(printf 'curl -fsSL --proto '"'"'=https'"'"' --tlsv1.2 https://openclaw.ai/install-cli.sh | bash -s --'; printf ' %q' "${install_args[@]}")"
}

verify_install() {
  log "Verifying OpenClaw install."
  sudo -iu "$OPENCLAW_USER" env \
    PATH="$OPENCLAW_PREFIX/bin:$PATH" \
    OPENCLAW_HOME="$OPENCLAW_HOME" \
    OPENCLAW_STATE_DIR="$OPENCLAW_PREFIX" \
    bash -lc 'openclaw --version'

  sudo -iu "$OPENCLAW_USER" env \
    PATH="$OPENCLAW_PREFIX/bin:$PATH" \
    OPENCLAW_HOME="$OPENCLAW_HOME" \
    OPENCLAW_STATE_DIR="$OPENCLAW_PREFIX" \
    bash -lc 'openclaw doctor || true'
}

print_next_steps() {
  cat <<EOF

OpenClaw is installed for user '$OPENCLAW_USER'.

Complete onboarding interactively:
  sudo -iu $OPENCLAW_USER
  openclaw onboard --install-daemon
  openclaw status
  openclaw dashboard
EOF
}

main() {
  require_root
  set_defaults
  require_command apt-get
  install_packages
  ensure_user
  enable_linger
  write_profile
  install_openclaw
  verify_install
  print_next_steps
}

main "$@"
