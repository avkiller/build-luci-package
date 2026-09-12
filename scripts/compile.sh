#!/usr/bin/env bash
set -euo pipefail
pkg=$1 logdir=$2
mkdir -p "$logdir"
make_cmd=${MAKE:-make}
jobs=$(nproc 2>/dev/null || echo 2)
if $make_cmd "package/$pkg/compile" -j"$jobs" > "$logdir/$pkg.log" 2>&1; then
  exit 0
fi
echo "compile: $pkg failed at -j$jobs, retrying with -j1 V=s" >&2
if $make_cmd "package/$pkg/compile" -j1 V=s > "$logdir/$pkg.log" 2>&1; then
  exit 0
fi
echo "compile: $pkg failed" >&2
tail -n 60 "$logdir/$pkg.log" >&2
exit 1
