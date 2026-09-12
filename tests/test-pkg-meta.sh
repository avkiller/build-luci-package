#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/c"; printf 'Package: luci-theme-a\nVersion: 1.2.3-r4\nArchitecture: all\nDescription: x\n' > "$tmp/c/control"
tar -C "$tmp/c" -czf "$tmp/control.tar.gz" ./control
echo 2.0 > "$tmp/debian-binary"; mkdir -p "$tmp/d"; tar -C "$tmp/d" -czf "$tmp/data.tar.gz" .
tar -C "$tmp" -czf "$tmp/luci-theme-a_1.2.3-r4_all.ipk" ./debian-binary ./control.tar.gz ./data.tar.gz
got=$(bash scripts/pkg-meta.sh "$tmp/luci-theme-a_1.2.3-r4_all.ipk")
[ "$got" = "$(printf 'luci-theme-a\t1.2.3-r4\tall')" ] || { echo "ipk: $got"; exit 1; }

mkdir -p "$tmp/bin"; cat > "$tmp/bin/apk" <<'EOS'
#!/usr/bin/env bash
printf '  name: luci-mod-x\n  version: 26.255.1~abc\n  arch: noarch\n  depends: # 1 items\n'
EOS
chmod +x "$tmp/bin/apk"
got=$(APK="$tmp/bin/apk" bash scripts/pkg-meta.sh "$tmp/luci-mod-x-26.255.1~abc.apk")
[ "$got" = "$(printf 'luci-mod-x\t26.255.1~abc\tnoarch')" ] || { echo "apk: $got"; exit 1; }
