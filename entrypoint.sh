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

# --- Index & Sign generated packages in $OUT ---
should_index=false
case "${INDEX:-true}" in
  1|true|TRUE|yes|YES) should_index=true ;;
esac

find_pkg_dirs() {
  local ext="$1"
  local found=0
  while IFS= read -r -d '' d; do
    printf '%s\0' "$d"
    found=1
  done < <(find "$OUT" -type f -name "*.$ext" -exec dirname {} \; | sort -u | tr '\n' '\0')
  [ "$found" -eq 1 ] || printf '%s\0' "$OUT"
}

index_and_sign_ipk() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  ls "$dir"/*.ipk >/dev/null 2>&1 || return 0

  local idx_script="/builder/scripts/ipkg-make-index.sh"
  local json_script="/builder/scripts/make-index-json.py"
  local usign_bin="/builder/staging_dir/host/bin/usign"
  local priv_key="/builder/key-build"

  [ -x "$usign_bin" ] || usign_bin="$(command -v usign || true)"

  if [ -x "$idx_script" ]; then
    (
      cd "$dir"
      PATH="/builder/staging_dir/host/bin:$PATH" "$idx_script" . > Packages
      gzip -9c Packages > Packages.gz
      if [ -f "$json_script" ]; then
        PATH="/builder/staging_dir/host/bin:$PATH" python3 "$json_script" . > Packages.json || true
      fi
    )
    echo "✅ Generated ipk index (Packages, Packages.gz) in $dir"
  else
    echo "⚠️ ipkg-make-index.sh not found, skip ipk index in $dir" >&2
    return 0
  fi

  if [ -s "$priv_key" ] && [ -n "${usign_bin:-}" ] && [ -x "$usign_bin" ]; then
    "$usign_bin" -S -m "$dir/Packages" -s "$priv_key" -x "$dir/Packages.sig"
    echo "✅ Signed ipk index -> $dir/Packages.sig"
  else
    echo "ℹ️ Skip ipk Packages.sig (missing key-build or usign)"
  fi
}

index_and_sign_apk() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  ls "$dir"/*.apk >/dev/null 2>&1 || return 0

  local apk_bin="/builder/staging_dir/host/bin/apk"
  local priv_key="/builder/private-key.pem"
  [ -x "$apk_bin" ] || apk_bin="${APK:-$(command -v apk || true)}"

  if [ -z "${apk_bin:-}" ] || [ ! -x "$apk_bin" ]; then
    echo "⚠️ apk binary not found, skip apk index in $dir" >&2
    return 0
  fi

  (
    cd "$dir"
    "$apk_bin" index --no-warnings -o packages.adb ./*.apk
  )
  echo "✅ Generated apk index -> $dir/packages.adb"

  if [ -s "$priv_key" ]; then
    if "$apk_bin" adbsign --help >/dev/null 2>&1; then
      "$apk_bin" adbsign --key "$priv_key" "$dir/packages.adb"
      echo "✅ Signed apk index via adbsign in $dir"
    elif "$apk_bin" sign --help >/dev/null 2>&1; then
      "$apk_bin" sign --sign-key "$priv_key" "$dir/packages.adb" || "$apk_bin" sign --key "$priv_key" "$dir/packages.adb"
      echo "✅ Signed apk index via sign in $dir"
    else
      echo "⚠️ apk subcommand for signing not found; check $dir/packages.adb" >&2
    fi
  else
    echo "ℹ️ Skip apk index signing (missing private-key.pem)"
  fi
}

if [ "$should_index" = true ]; then
  while IFS= read -r -d '' d; do
    if [ "$PKG_TYPE" = "ipk" ]; then
      index_and_sign_ipk "$d"
    else
      index_and_sign_apk "$d"
    fi
  done < <(find_pkg_dirs "$PKG_TYPE")
else
  echo "ℹ️ INDEX disabled, skip generating repository index"
fi


if [ "${INDEX_TOOLS:-true}" = true ]; then
  mkdir -p "$OUT/.tools"
  [ ! -f staging_dir/host/bin/.apk.bin ] || cp staging_dir/host/bin/.apk.bin "$OUT/.tools/apk"
  [ ! -f staging_dir/host/bin/.usign.bin ] || cp staging_dir/host/bin/.usign.bin "$OUT/.tools/usign"
  for f in scripts/ipkg-make-index.sh scripts/make-index-json.py; do [ ! -f "$f" ] || cp "$f" "$OUT/.tools/"; done
  chmod +x "$OUT/.tools/"*
  ls "$OUT/.tools"
fi
echo "pkg_type=$PKG_TYPE" > "$OUT/.pkg_type"
