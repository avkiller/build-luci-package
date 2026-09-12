#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
V=scripts/validate-spec.sh
ok()  { printf '%s' "$1" | bash "$V" 2>/dev/null; }
bad() { if printf '%s' "$1" | bash "$V" >/dev/null 2>&1; then echo "should reject: $1"; exit 1; fi; }
sha=0123456789abcdef0123456789abcdef01234567

out=$(ok '[{"pkg":"luci-theme-a","path":"."}]')
[ "$(jq -r '.[0].kind' <<<"$out")" = local ] || { echo "local kind"; exit 1; }
[ "$(jq -r '.[0].arch' <<<"$out")" = all ]   || { echo "arch default"; exit 1; }
[ "$(jq -r '.[0].langs|length' <<<"$out")" = 0 ] || { echo "langs default"; exit 1; }

out=$(ok "[{\"pkg\":\"luci-theme-b\",\"repo\":\"eamonxg/luci-theme-b\",\"ref\":\"$sha\"}]")
[ "$(jq -r '.[0].kind' <<<"$out")" = repo ] || { echo "repo kind"; exit 1; }
[ "$(jq -r '.[0].url' <<<"$out")" = "https://github.com/eamonxg/luci-theme-b.git" ] || { echo "url"; exit 1; }

out=$(ok "[{\"pkg\":\"luci-mod-x\",\"repo\":\"https://example.com/luci.git\",\"ref\":\"$sha\",\"feed\":\"luci\",\"arch\":[\"x86_64\"],\"langs\":[\"zh-cn\"]}]")
[ "$(jq -r '.[0].kind' <<<"$out")" = feed ] || { echo "feed kind"; exit 1; }
[ "$(jq -r '.[0].url' <<<"$out")" = "https://example.com/luci.git" ] || { echo "url passthrough"; exit 1; }
[ "$(jq -c '.[0].arch' <<<"$out")" = '["x86_64"]' ] || { echo "arch list"; exit 1; }

bad '[{"path":"."}]'
bad '[{"pkg":"a","path":".","repo":"x/y"}]'
bad '[{"pkg":"a"}]'
bad '[{"pkg":"a","path":".","bogus":1}]'
bad "[{\"pkg\":\"a\",\"repo\":\"x/y\",\"ref\":\"$sha\",\"feed\":\"nope\"}]"
bad '[{"pkg":"a","repo":"x/y","ref":"main"}]'
bad '[{"pkg":"a","path":"."},{"pkg":"a","path":"."}]'
bad "[{\"pkg\":\"a\",\"repo\":\"x/y\",\"ref\":\"$sha\",\"feed\":\"luci\"},{\"pkg\":\"b\",\"repo\":\"x/z\",\"ref\":\"$sha\",\"feed\":\"luci\"}]"
bad '[{"pkg":"a","path":".","arch":"x86_64"}]'
bad '[{"pkg":"a","path":".","langs":["ZH"]}]'
bad '{"pkg":"a"}'
