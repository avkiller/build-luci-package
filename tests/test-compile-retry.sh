#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/make" <<'EOS'
#!/usr/bin/env bash
echo "$@" >> "$MAKE_CALLS"
n=$(wc -l < "$MAKE_CALLS")
[ "$n" -ge "${FAIL_UNTIL:-0}" ] || { echo "boom"; exit 2; }
echo built
EOS
chmod +x "$tmp/make"

: > "$tmp/calls"; MAKE_CALLS="$tmp/calls" FAIL_UNTIL=2 MAKE="$tmp/make" bash scripts/compile.sh luci-theme-a "$tmp/logs"
[ "$(wc -l < "$tmp/calls" | tr -d ' ')" = 2 ] || { echo "expected 2 make calls"; exit 1; }
grep -q -- '-j1 V=s' "$tmp/calls" || { echo "second call must be -j1 V=s"; exit 1; }
grep -q 'package/luci-theme-a/compile' "$tmp/calls" || { echo "target"; exit 1; }
[ -s "$tmp/logs/luci-theme-a.log" ] || { echo "log missing"; exit 1; }

: > "$tmp/calls"; MAKE_CALLS="$tmp/calls" FAIL_UNTIL=1 MAKE="$tmp/make" bash scripts/compile.sh luci-theme-a "$tmp/logs2"
[ "$(wc -l < "$tmp/calls" | tr -d ' ')" = 1 ] || { echo "success must not retry"; exit 1; }

: > "$tmp/calls"
if MAKE_CALLS="$tmp/calls" FAIL_UNTIL=9 MAKE="$tmp/make" bash scripts/compile.sh luci-theme-a "$tmp/logs3" 2>/dev/null; then echo "must fail"; exit 1; fi
[ "$(wc -l < "$tmp/calls" | tr -d ' ')" = 2 ] || { echo "exactly one retry"; exit 1; }
