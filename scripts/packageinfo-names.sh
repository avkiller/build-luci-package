#!/usr/bin/env bash
set -euo pipefail
info=$1 mk=$2
out=$(awk -v mk="$mk" '
  /^Source-Makefile: / { f = ($2 == mk) }
  f && /^Package: /     { print $2 }
' "$info")
[ -n "$out" ] || { echo "packageinfo-names: no packages for $mk" >&2; exit 1; }
printf '%s\n' "$out"
