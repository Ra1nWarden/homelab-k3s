#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/secrets/encrypt-env.sh <plaintext.env> <encrypted.env.sops>

Encrypt a dotenv file with SOPS. The output path is used for .sops.yaml rule
selection through --filename-override.
USAGE
}

die() {
  printf '[sops-encrypt-env] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

main() {
  local input
  local output
  local tmp

  [ "$#" -eq 2 ] || {
    usage >&2
    exit 2
  }

  input="$1"
  output="$2"

  require_command sops

  [ -f "$input" ] || die "Plaintext env file not found: $input"
  case "$output" in
    *.sops|*.sops.*|*.env.sops) ;;
    *) die "Encrypted output should include .sops in the filename: $output" ;;
  esac

  mkdir -p "$(dirname "$output")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/sops-env.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT

  sops encrypt \
    --input-type dotenv \
    --output-type dotenv \
    --filename-override "$output" \
    "$input" >"$tmp"

  mv "$tmp" "$output"
  trap - EXIT
}

main "$@"
