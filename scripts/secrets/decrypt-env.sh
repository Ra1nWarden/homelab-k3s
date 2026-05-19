#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/secrets/decrypt-env.sh [--force] <encrypted.env.sops> <plaintext.env>

Decrypt a SOPS dotenv file to a local plaintext env file. The script refuses to
overwrite an existing plaintext output unless --force is passed.
USAGE
}

die() {
  printf '[sops-decrypt-env] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

main() {
  local force
  local input
  local output
  local tmp

  force=0
  if [ "${1:-}" = "--force" ]; then
    force=1
    shift
  fi

  [ "$#" -eq 2 ] || {
    usage >&2
    exit 2
  }

  input="$1"
  output="$2"

  require_command sops

  [ -f "$input" ] || die "Encrypted env file not found: $input"
  if [ -e "$output" ] && [ "$force" != "1" ]; then
    die "Refusing to overwrite existing file: $output"
  fi

  mkdir -p "$(dirname "$output")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/sops-env.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT

  sops decrypt \
    --input-type dotenv \
    --output-type dotenv \
    "$input" >"$tmp"

  chmod 600 "$tmp"
  mv "$tmp" "$output"
  trap - EXIT
}

main "$@"
