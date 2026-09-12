#!/usr/bin/env bash
set -euo pipefail
spec=$1 work=$2
mkdir -p "$work/feed" "$work/src"
: > "$work/feed-overrides.txt"
cp "$spec" "$work/spec.json"

sync_tree() {
  rsync -a --delete --exclude .github --exclude .vscode --exclude .dev "$1/" "$2/"
  if [ -f "$2/Makefile" ] && grep -q '^include \.\./\.\./luci\.mk' "$2/Makefile"; then
    sed -i.bak 's|^include \.\./\.\./luci\.mk|include $(TOPDIR)/feeds/luci/luci.mk|' "$2/Makefile"
    rm -f "$2/Makefile.bak"
  fi
}

jq -c '.[]' "$spec" | while read -r e; do
  pkg=$(jq -r .pkg <<<"$e"); kind=$(jq -r .kind <<<"$e")
  case "$kind" in
    local)
      sync_tree "$(jq -r .path <<<"$e")" "$work/feed/$pkg" ;;
    repo)
      url=$(jq -r .url <<<"$e"); ref=$(jq -r .ref <<<"$e")
      rm -rf "$work/src/$pkg"
      git clone -q "$url" "$work/src/$pkg"
      git -C "$work/src/$pkg" -c advice.detachedHead=false checkout -q "$ref"
      sync_tree "$work/src/$pkg" "$work/feed/$pkg" ;;
    feed)
      printf '%s %s %s\n' "$(jq -r .feed <<<"$e")" "$(jq -r .url <<<"$e")" "$(jq -r .ref <<<"$e")" \
        >> "$work/feed-overrides.txt" ;;
    *) echo "materialize: unknown kind $kind" >&2; exit 1 ;;
  esac
done
sort -u -o "$work/feed-overrides.txt" "$work/feed-overrides.txt"
