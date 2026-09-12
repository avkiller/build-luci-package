#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkgit() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

mkdir -p "$tmp/local"; printf 'include $(TOPDIR)/rules.mk\ninclude ../../luci.mk\n' > "$tmp/local/Makefile"
git init -q "$tmp/local"; mkgit "$tmp/local" add -A; mkgit "$tmp/local" commit -q -m init
mkdir -p "$tmp/local/.github"; echo x > "$tmp/local/.github/ci.yml"

mkdir -p "$tmp/remote"; printf 'include $(TOPDIR)/feeds/luci/luci.mk\n' > "$tmp/remote/Makefile"
git init -q -b main "$tmp/remote"; mkgit "$tmp/remote" add -A; mkgit "$tmp/remote" commit -q -m one
echo 2 > "$tmp/remote/v"; mkgit "$tmp/remote" add -A; mkgit "$tmp/remote" commit -q -m two
old=$(git -C "$tmp/remote" rev-parse HEAD~1)
sha=0123456789abcdef0123456789abcdef01234567

cat > "$tmp/spec.json" <<EOS
[
 {"pkg":"luci-theme-a","kind":"local","path":"$tmp/local","arch":"all","langs":[]},
 {"pkg":"luci-theme-b","kind":"repo","url":"file://$tmp/remote","ref":"$old","arch":"all","langs":[]},
 {"pkg":"luci-mod-x","kind":"feed","url":"https://example.com/luci.git","ref":"$sha","feed":"luci","arch":"all","langs":[]},
 {"pkg":"luci-mod-y","kind":"feed","url":"https://example.com/luci.git","ref":"$sha","feed":"luci","arch":"all","langs":[]}
]
EOS
bash scripts/materialize.sh "$tmp/spec.json" "$tmp/work"

grep -q 'include $(TOPDIR)/feeds/luci/luci.mk' "$tmp/work/feed/luci-theme-a/Makefile" || { echo "include not rewritten"; exit 1; }
[ -d "$tmp/work/feed/luci-theme-a/.git" ] || { echo ".git dropped"; exit 1; }
[ ! -e "$tmp/work/feed/luci-theme-a/.github" ] || { echo ".github should be excluded"; exit 1; }
[ "$(git -C "$tmp/work/feed/luci-theme-b" rev-parse HEAD)" = "$old" ] || { echo "repo not at ref"; exit 1; }
[ ! -e "$tmp/work/feed/luci-theme-b/v" ] || { echo "wrong tree"; exit 1; }
[ "$(cat "$tmp/work/feed-overrides.txt")" = "luci https://example.com/luci.git $sha" ] || { echo "overrides: $(cat "$tmp/work/feed-overrides.txt")"; exit 1; }
[ ! -e "$tmp/work/feed/luci-mod-x" ] || { echo "feed kind must not materialize"; exit 1; }
cmp -s "$tmp/spec.json" "$tmp/work/spec.json" || { echo "spec not copied"; exit 1; }
