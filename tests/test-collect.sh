#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sdk="$tmp/sdk"; mkdir -p "$sdk/tmp" "$sdk/bin/packages/x86_64/eamonxg" "$sdk/bin/packages/x86_64/luci"
cp tests/fixtures/packageinfo.txt "$sdk/tmp/.packageinfo"
for f in luci-mod-dashboard-26.255.1~abc.apk luci-i18n-dashboard-de-26.255.1~abc.apk luci-i18n-dashboard-zh-cn-26.255.1~abc.apk luci-mod-dashboard-extra-1.apk; do echo "$f" > "$sdk/bin/packages/x86_64/luci/$f"; done
echo a > "$sdk/bin/packages/x86_64/eamonxg/luci-theme-aurora-1.3.1-r2.apk"

cat > "$tmp/meta" <<'EOS'
#!/usr/bin/env bash
b=$(basename "$1")
case "$b" in
  luci-theme-aurora-*)   printf 'luci-theme-aurora\t1.3.1-r2\tnoarch\n' ;;
  luci-mod-dashboard-26*) printf 'luci-mod-dashboard\t26.255.1~abc\tnoarch\n' ;;
  luci-i18n-dashboard-de-*) printf 'luci-i18n-dashboard-de\t26.255.1~abc\tnoarch\n' ;;
  luci-i18n-dashboard-zh-cn-*) printf 'luci-i18n-dashboard-zh-cn\t26.255.1~abc\tnoarch\n' ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$tmp/meta"
sha=0123456789abcdef0123456789abcdef01234567
cat > "$tmp/spec.json" <<EOS
[{"pkg":"luci-theme-aurora","kind":"local","path":".","arch":"all","langs":[]},
 {"pkg":"luci-mod-dashboard","kind":"feed","url":"u","ref":"$sha","feed":"luci","arch":"all","langs":["zh-cn"]}]
EOS
PKG_META="$tmp/meta" scripts/collect.py "$tmp/spec.json" eamonxg x86_64 apk 25.12.5 "$sdk" "$tmp/out"

[ "$(ls "$tmp/out"/*.apk | wc -l | tr -d ' ')" = 4 ] || { echo "expected 4 files, got: $(ls "$tmp/out")"; exit 1; }
[ ! -e "$tmp/out/luci-mod-dashboard-extra-1.apk" ] || { echo "prefix collision"; exit 1; }
bi="$tmp/out/build-info.json"
[ "$(jq -r .pkg_type "$bi")" = apk ] || { echo "pkg_type"; exit 1; }
[ "$(jq -r '.packages|length' "$bi")" = 2 ] || { echo "packages"; exit 1; }
[ "$(jq -r '.packages[1].files|length' "$bi")" = 3 ] || { echo "dashboard files"; exit 1; }
[ "$(jq -r '.packages[1].ref' "$bi")" = "$sha" ] || { echo "ref"; exit 1; }
[ "$(jq -r '.packages[0].files[0].version' "$bi")" = "1.3.1-r2" ] || { echo "version"; exit 1; }
[ "$(jq -r '.packages[0].files[0].sha256' "$bi")" = "$(shasum -a 256 "$tmp/out/luci-theme-aurora-1.3.1-r2.apk" | cut -d' ' -f1)" ] || { echo "sha"; exit 1; }

cat > "$tmp/spec2.json" <<EOS
[{"pkg":"luci-theme-aurora","kind":"local","path":".","arch":["x86_64"],"langs":[]}]
EOS
if PKG_META="$tmp/meta" scripts/collect.py "$tmp/spec2.json" eamonxg x86_64 apk 25.12.5 "$sdk" "$tmp/out2" 2>"$tmp/err"; then echo "arch mismatch must fail"; exit 1; fi
grep -q 'luci-theme-aurora' "$tmp/err" || { echo "error must name the package"; exit 1; }
