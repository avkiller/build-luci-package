#!/usr/bin/env bash
set -euo pipefail
f=$1
case "$f" in
  *.apk)
    "${APK:-apk}" adbdump "$f" | awk '
      /^  name: /    && !n { n=$2 }
      /^  version: / && !v { v=$2 }
      /^  arch: /    && !a { a=$2 }
      END { if (!n||!v||!a) exit 1; printf "%s\t%s\t%s\n", n, v, a }' ;;
  *.ipk)
    tar -xzOf "$f" ./control.tar.gz | tar -xzOf - ./control | awk '
      /^Package: /      { n=$2 }
      /^Version: /      { v=$2 }
      /^Architecture: / { a=$2 }
      END { if (!n||!v||!a) exit 1; printf "%s\t%s\t%s\n", n, v, a }' ;;
  *) echo "pkg-meta: unsupported file $f" >&2; exit 1 ;;
esac
