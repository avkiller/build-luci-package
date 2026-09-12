#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
S=scripts/packageinfo-names.sh; F=tests/fixtures/packageinfo.txt
got=$(bash "$S" "$F" package/feeds/luci/luci-mod-dashboard/Makefile | tr '\n' ' ')
[ "$got" = "luci-mod-dashboard luci-i18n-dashboard-de luci-i18n-dashboard-zh-cn " ] || { echo "got: $got"; exit 1; }
got=$(bash "$S" "$F" package/feeds/eamonxg/luci-theme-aurora/Makefile | tr '\n' ' ')
[ "$got" = "luci-theme-aurora " ] || { echo "got: $got"; exit 1; }
if bash "$S" "$F" package/feeds/luci/nope/Makefile >/dev/null 2>&1; then echo "missing section must fail"; exit 1; fi
