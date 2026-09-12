#!/usr/bin/env bash
set -euo pipefail
spec=$1 feed_name=$2 arch=$3 pkg_type=$4 sdk=$5 root=$6 out=$7
here=$(cd "$(dirname "$0")" && pwd)
meta=${PKG_META:-$here/pkg-meta.sh}
mkdir -p "$out"
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
fsize() { if stat -c %s "$1" >/dev/null 2>&1; then stat -c %s "$1"; else stat -f %z "$1"; fi; }
noarch_ok() { [ "$1" = noarch ] || [ "$1" = all ]; }

pkgs='[]'
while read -r e; do
  pkg=$(jq -r .pkg <<<"$e"); kind=$(jq -r .kind <<<"$e"); declared=$(jq -c .arch <<<"$e")
  if [ "$kind" = feed ]; then mk="package/feeds/$(jq -r .feed <<<"$e")/$pkg/Makefile"; else mk="package/feeds/$feed_name/$pkg/Makefile"; fi
  files='[]'
  while read -r name; do
    found=$(find "$root/bin/packages/$arch" -type f \( -name "${name}-[0-9]*.apk" -o -name "${name}_*.ipk" \) | sort)
    [ -n "$found" ] || { echo "collect: no output for $name (from $pkg)" >&2; exit 1; }
    while read -r f; do
      IFS=$'\t' read -r n v a < <("$meta" "$f")
      [ "$n" = "$name" ] || { echo "collect: $f reports name $n, expected $name" >&2; exit 1; }
      if [ "$declared" = '"all"' ]; then
        noarch_ok "$a" || { echo "collect: $pkg declares arch all but $f is built for $a" >&2; exit 1; }
      else
        [ "$a" = "$arch" ] || { echo "collect: $pkg declares an arch-specific build but $f is $a, expected $arch" >&2; exit 1; }
      fi
      cp -f "$f" "$out/"
      files=$(jq -c --arg file "$(basename "$f")" --arg n "$n" --arg v "$v" --arg a "$a" \
        --argjson s "$(fsize "$f")" --arg h "$(sha "$f")" \
        '. + [{file:$file,name:$n,version:$v,arch:$a,size:$s,sha256:$h}]' <<<"$files")
    done <<<"$found"
  done < <("$here/packageinfo-names.sh" "$root/tmp/.packageinfo" "$mk")
  pkgs=$(jq -c --arg p "$pkg" --arg k "$kind" --arg r "$(jq -r '.ref // ""' <<<"$e")" --argjson d "$declared" --argjson f "$files" \
    '. + [{pkg:$p,kind:$k,ref:$r,declared_arch:$d,files:$f}]' <<<"$pkgs")
done < <(jq -c '.[]' "$spec")

jq -n --arg sdk "$sdk" --arg arch "$arch" --arg t "$pkg_type" --argjson p "$pkgs" \
  '{sdk:$sdk, arch:$arch, pkg_type:$t, packages:$p}' > "$out/build-info.json"
