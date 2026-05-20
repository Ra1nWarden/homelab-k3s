#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  render-template.sh path/to/template path/to/output

Replaces @VAR_NAME@ placeholders with values from the current environment.
USAGE
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 2
fi

template_file="$1"
output_file="$2"

[ -f "$template_file" ] || {
  printf 'render-template: template not found: %s\n' "$template_file" >&2
  exit 1
}

perl -0pe 's/@([A-Z0-9_]+)@/exists $ENV{$1} ? $ENV{$1} : $&/ge' \
  "$template_file" > "$output_file"
