#!/usr/bin/env bash
set -euo pipefail
cd /builder
[ ! -f setup.sh ] || bash setup.sh
export HOME=/tmp
git config --global --add safe.directory '*'

FEED_NAME=${FEED_NAME:-eamonxg}
WORK=/work; OUT=$WORK/out; S=/scripts
mkdir -p "$OUT/logs"

sed -e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
    -e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
    -e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
    feeds.conf.default > feeds.conf
overridden=""
while read -r name url sha; do
  [ -n "$name" ] || continue
  grep -q "^src-git $name " feeds.conf || { echo "entrypoint: feed $name not in feeds.conf.default" >&2; exit 1; }
  sed -i "s#^src-git $name .*#src-git $name $url^$sha#" feeds.conf
  overridden="$overridden $name"
done < "$WORK/feed-overrides.txt"
echo "src-link $FEED_NAME $WORK/feed" >> feeds.conf
cat feeds.conf

if [ -n "${USIGN_KEY:-}" ]; then printf '%s\n' "$USIGN_KEY" > key-build; fi
if [ -n "${APK_KEY:-}" ]; then printf '%s\n' "$APK_KEY" > private-key.pem; fi

# shellcheck disable=SC2086
./scripts/feeds update -f base luci $overridden "$FEED_NAME"

langs=$(cat "$WORK/langs.txt")
install="luci-base"
for l in $langs; do install="$install luci-i18n-base-$l"; done
# shellcheck disable=SC2086
./scripts/feeds install -f $install
while IFS=$'\t' read -r pkg kind feed; do
  [ -n "$pkg" ] || continue
  if [ "$kind" = feed ]; then
    ./scripts/feeds install -f -p "$feed" "$pkg"
  else
    ./scripts/feeds install -f -p "$FEED_NAME" "$pkg"
  fi
done < "$WORK/pkgs.tsv"

{ [ -z "${USIGN_KEY:-}${APK_KEY:-}" ] || echo "CONFIG_SIGNED_PACKAGES=y"
  for l in $langs; do
    case "$l" in zh-cn) sym=zh_Hans ;; zh-tw) sym=zh_Hant ;; *) sym=$l ;; esac
    echo "CONFIG_LUCI_LANG_$sym=y"
  done; } >> .config
make defconfig >/dev/null

if grep -q '^CONFIG_USE_APK=y' .config; then PKG_TYPE=apk; else PKG_TYPE=ipk; fi
export APK=/builder/staging_dir/host/bin/apk

while IFS=$'\t' read -r pkg kind feed; do
  [ -n "$pkg" ] || continue
  echo "::group::compile $pkg"
  "$S/compile.sh" "$pkg" "$OUT/logs"
  echo "::endgroup::"
done < "$WORK/pkgs.tsv"

python3 "$S/collect.py" "$WORK/spec.json" "$FEED_NAME" "$ARCH" "$PKG_TYPE" "$SDK" /builder "$OUT"

if [ "${INDEX_TOOLS:-true}" = true ]; then
  mkdir -p "$OUT/.tools"
  [ ! -f staging_dir/host/bin/.apk.bin ] || cp staging_dir/host/bin/.apk.bin "$OUT/.tools/apk"
  [ ! -f staging_dir/host/bin/.usign.bin ] || cp staging_dir/host/bin/.usign.bin "$OUT/.tools/usign"
  for f in scripts/ipkg-make-index.sh scripts/make-index-json.py; do [ ! -f "$f" ] || cp "$f" "$OUT/.tools/"; done
  chmod +x "$OUT/.tools/"*
  ls "$OUT/.tools"
fi
echo "pkg_type=$PKG_TYPE" > "$OUT/.pkg_type"
