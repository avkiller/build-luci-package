# build-luci-package v2 构建核心 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 build-luci-package 重写为一个在官方 OpenWrt SDK 镜像里构建一批包、产出带元数据目录的 composite action，外加一个发 GitHub Release 的薄封装。

**Architecture:** host 侧脚本校验并物化包来源到一个 src-link feed 目录，然后 `docker run ghcr.io/openwrt/sdk:<arch>-<sdk>` 挂载自己的 entrypoint；容器内组装 feeds.conf（支持覆盖上游 feed 为 fork）、编译（失败降 `-j1` 重试）、按 `tmp/.packageinfo` 精确收集子包、校验真实架构、写 `build-info.json`，并导出索引工具包。索引不在容器内做。

**Tech Stack:** GitHub composite action、bash、jq、docker、OpenWrt SDK 镜像（ghcr.io/openwrt/sdk）、softprops/action-gh-release。

**Spec:** `/Users/eamon/Developer/github/luci-theme/openwrt-cloud/docs/superpowers/specs/2026-09-12-feed-infra-v2-design.md` §1、§7、§8（本地文件，仓库不提交）。

## Global Constraints

- 分支 `v2` 上开发；`master` 保持 v1 直到全部调用方迁完。commit 不 push，等用户明确指示。
- 所有脚本 `#!/usr/bin/env bash` + `set -euo pipefail`；只依赖 bash、coreutils、jq、git、rsync、tar、docker。
- 测试用 `tests/test-*.sh` + `tests/run.sh`，与 openwrt-cloud 的约定一致；每个脚本至少一个单元测试。
- 不写解释性注释，改动理由进 commit body。commit 尾部只允许 `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`；提交后 `git log -1 --format=%B | grep -iE 'session|claude\.ai'` 必须为空。
- `kind: repo` 与 `kind: feed` 的 `ref` 必须是 40 位十六进制 sha；分支解析是调用方（openwrt-cloud 的 plan.sh）的事。
- 声明 `arch: "all"` 的包产物架构必须是 `noarch`（apk）或 `all`（ipk）；其余必须等于当前 `arch`。不一致即失败。
- 镜像默认 `ghcr.io/openwrt/sdk`，tag 为 `<arch>-<sdk>`；容器内 SDK 根目录 `/builder`；snapshot 镜像需先 `bash setup.sh`。

---

## 文件结构

```
build-luci-package/
  action.yml                      构建核心 composite action（v2，替换 v1 内容）
  entrypoint.sh                   容器内主流程
  scripts/validate-spec.sh        host：校验 packages JSON，输出规范化 spec（补 kind、url）
  scripts/materialize.sh          host：物化 local/repo 到 $WORK/feed/<pkg>，写 feed-overrides.txt
  scripts/packageinfo-names.sh    容器：从 tmp/.packageinfo 取某 Source-Makefile 的全部子包名
  scripts/pkg-meta.sh             容器：从 .apk/.ipk 读 name/version/arch
  scripts/compile.sh              容器：make compile，失败降 -j1 V=s 重试一次
  scripts/collect.sh              容器：按名收集产物、校验架构、写 build-info.json
  release/action.yml              GitHub Release 薄封装（从 v1 尾部移植）
  tests/run.sh
  tests/test-validate-spec.sh
  tests/test-materialize.sh
  tests/test-packageinfo-names.sh
  tests/test-compile-retry.sh
  tests/test-collect.sh
  tests/fixtures/packageinfo.txt
  tests/fixtures/hello-arch/      最小 C 包（集成测试的架构用例）
  .github/workflows/test-action.yml
  README.md
```

---

### Task 0: 建分支与测试骨架

**Files:**
- Create: `tests/run.sh`
- Modify: `.github/workflows/test-action.yml`（先只改触发分支，内容 Task 9 重写）

- [ ] **Step 1: 建分支**

```bash
cd /Users/eamon/Developer/github/luci-theme/build-luci-package
git switch -c v2
```

- [ ] **Step 2: 写 tests/run.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
fail=0
for t in test-*.sh; do
  [ -e "$t" ] || continue
  echo "== $t"
  if bash "$t"; then echo "   PASS"; else echo "   FAIL"; fail=1; fi
done
exit "$fail"
```

- [ ] **Step 3: 运行，确认空跑通过**

Run: `bash tests/run.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 4: Commit**

```bash
git add tests/run.sh
git commit -m "test: add bash test runner" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 1: validate-spec.sh

**Files:**
- Create: `scripts/validate-spec.sh`
- Test: `tests/test-validate-spec.sh`

**Interfaces:**
- Produces: `scripts/validate-spec.sh` 从 stdin 读 JSON 数组，stdout 输出规范化数组；每项形如
  `{pkg, kind: "local"|"repo"|"feed", path?, url?, ref?, feed?, arch: "all"|"any"|[...], langs: [...]}`。
  非法输入退出码 1，stderr 一行原因。后续 materialize.sh、collect.sh 只消费规范化形式。

- [ ] **Step 1: 写失败测试**

```bash
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
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test-validate-spec.sh`
Expected: 报 `scripts/validate-spec.sh: No such file` 或首个断言失败，退出码非 0。

- [ ] **Step 3: 实现**

```bash
#!/usr/bin/env bash
set -euo pipefail
die() { echo "validate-spec: $*" >&2; exit 1; }
in=$(cat)
jq -e 'type=="array"' <<<"$in" >/dev/null 2>&1 || die "packages must be a JSON array"
jq -e '
  def allowed: ["pkg","repo","path","ref","feed","arch","langs"];
  def feeds: ["base","packages","luci","routing","telephony","video"];
  def sha: test("^[0-9a-f]{40}$");
  def lang: test("^[a-z]{2,3}(-[a-z]{2,4})?$");
  all(.[]; type=="object")
  and all(.[]; (keys - allowed) == [])
  and all(.[]; (.pkg|type)=="string" and (.pkg|length)>0)
  and all(.[]; ((has("path")|not) and has("repo")) or (has("path") and (has("repo")|not)))
  and all(.[]; (has("feed")|not) or (has("repo") and (.feed as $f | feeds | index($f)) != null))
  and all(.[]; (has("repo")|not) or ((.ref // "") | sha))
  and all(.[]; (has("path")|not) or (has("ref")|not))
  and all(.[]; (.arch // "all") as $a | ($a=="all" or $a=="any" or ($a|type=="array" and length>0 and all(.[]; type=="string"))))
  and all(.[]; (.langs // []) | type=="array" and all(.[]; type=="string" and lang))
  and ([.[].pkg] | length == (unique|length))
  and ([.[] | select(has("feed")) | {feed, repo, ref}] | (map(.feed)|unique|length) == (unique|length))
' <<<"$in" >/dev/null || die "invalid package spec"
jq '
  def url: if test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") then "https://github.com/\(.).git" else . end;
  map(
    (if has("feed") then "feed" elif has("repo") then "repo" else "local" end) as $kind
    | {pkg, kind: $kind}
    + (if $kind=="local" then {path} else {url: (.repo|url), ref} end)
    + (if $kind=="feed" then {feed} else {} end)
    + {arch: (.arch // "all"), langs: (.langs // [])}
  )
' <<<"$in"
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test-validate-spec.sh && echo OK`
Expected: `OK`。

- [ ] **Step 5: Commit**

```bash
git add scripts/validate-spec.sh tests/test-validate-spec.sh
git commit -m "feat: validate and normalise the package spec" -m "One schema for both the feed config and the action input. Unknown keys are rejected so typos surface at plan time, and refs for remote sources must already be resolved to a sha so a build is always pinned.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: materialize.sh

**Files:**
- Create: `scripts/materialize.sh`
- Test: `tests/test-materialize.sh`

**Interfaces:**
- Consumes: 规范化 spec（Task 1）。
- Produces: `scripts/materialize.sh <spec.json> <work-dir>`。结果：
  `<work>/feed/<pkg>/`（local/repo，含 .git，`include ../../luci.mk` 已改写）、
  `<work>/feed-overrides.txt`（每行 `<feed> <url> <sha>`，去重）、`<work>/spec.json`。

- [ ] **Step 1: 写失败测试**

```bash
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

cat > "$tmp/spec.json" <<EOF
[
 {"pkg":"luci-theme-a","kind":"local","path":"$tmp/local","arch":"all","langs":[]},
 {"pkg":"luci-theme-b","kind":"repo","url":"file://$tmp/remote","ref":"$old","arch":"all","langs":[]},
 {"pkg":"luci-mod-x","kind":"feed","url":"https://example.com/luci.git","ref":"$sha","feed":"luci","arch":"all","langs":[]},
 {"pkg":"luci-mod-y","kind":"feed","url":"https://example.com/luci.git","ref":"$sha","feed":"luci","arch":"all","langs":[]}
]
EOF
bash scripts/materialize.sh "$tmp/spec.json" "$tmp/work"

grep -q 'include $(TOPDIR)/feeds/luci/luci.mk' "$tmp/work/feed/luci-theme-a/Makefile" || { echo "include not rewritten"; exit 1; }
[ -d "$tmp/work/feed/luci-theme-a/.git" ] || { echo ".git dropped"; exit 1; }
[ ! -e "$tmp/work/feed/luci-theme-a/.github" ] || { echo ".github should be excluded"; exit 1; }
[ "$(git -C "$tmp/work/feed/luci-theme-b" rev-parse HEAD)" = "$old" ] || { echo "repo not at ref"; exit 1; }
[ ! -e "$tmp/work/feed/luci-theme-b/v" ] || { echo "wrong tree"; exit 1; }
[ "$(cat "$tmp/work/feed-overrides.txt")" = "luci https://example.com/luci.git $sha" ] || { echo "overrides: $(cat "$tmp/work/feed-overrides.txt")"; exit 1; }
[ ! -e "$tmp/work/feed/luci-mod-x" ] || { echo "feed kind must not materialize"; exit 1; }
cmp -s "$tmp/spec.json" "$tmp/work/spec.json" || { echo "spec not copied"; exit 1; }
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test-materialize.sh`
Expected: 找不到 `scripts/materialize.sh`，退出码非 0。

- [ ] **Step 3: 实现**

```bash
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
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test-materialize.sh && echo OK`
Expected: `OK`。

- [ ] **Step 5: Commit**

```bash
git add scripts/materialize.sh tests/test-materialize.sh
git commit -m "feat: materialise package sources into a src-link feed" -m "Local and repo sources are copied with their .git so luci.mk's findrev keeps deriving the version; the monorepo-style luci.mk include is rewritten here once instead of in every caller's workflow. Feed overrides are only recorded; the container rewrites feeds.conf.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: packageinfo-names.sh

**Files:**
- Create: `scripts/packageinfo-names.sh`
- Create: `tests/fixtures/packageinfo.txt`
- Test: `tests/test-packageinfo-names.sh`

**Interfaces:**
- Produces: `scripts/packageinfo-names.sh <packageinfo> <source-makefile-path>` 每行一个子包名；找不到段落退出码 1。

- [ ] **Step 1: 写夹具与失败测试**

`tests/fixtures/packageinfo.txt`：
```
Source-Makefile: package/feeds/luci/luci-base/Makefile

Package: luci-base
Version: 1
@@

Package: luci-i18n-base-zh-cn
Version: 1
@@

Source-Makefile: package/feeds/luci/luci-mod-dashboard/Makefile

Package: luci-mod-dashboard
Version: 1
@@

Package: luci-i18n-dashboard-de
Version: 1
@@

Package: luci-i18n-dashboard-zh-cn
Version: 1
@@

Source-Makefile: package/feeds/eamonxg/luci-theme-aurora/Makefile

Package: luci-theme-aurora
Version: 1
@@
```

`tests/test-packageinfo-names.sh`：
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
S=scripts/packageinfo-names.sh; F=tests/fixtures/packageinfo.txt
got=$(bash "$S" "$F" package/feeds/luci/luci-mod-dashboard/Makefile | tr '\n' ' ')
[ "$got" = "luci-mod-dashboard luci-i18n-dashboard-de luci-i18n-dashboard-zh-cn " ] || { echo "got: $got"; exit 1; }
got=$(bash "$S" "$F" package/feeds/eamonxg/luci-theme-aurora/Makefile | tr '\n' ' ')
[ "$got" = "luci-theme-aurora " ] || { echo "got: $got"; exit 1; }
if bash "$S" "$F" package/feeds/luci/nope/Makefile >/dev/null 2>&1; then echo "missing section must fail"; exit 1; fi
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test-packageinfo-names.sh`
Expected: 退出码非 0。

- [ ] **Step 3: 实现**

```bash
#!/usr/bin/env bash
set -euo pipefail
info=$1 mk=$2
out=$(awk -v mk="$mk" '
  /^Source-Makefile: / { f = ($2 == mk) }
  f && /^Package: /     { print $2 }
' "$info")
[ -n "$out" ] || { echo "packageinfo-names: no packages for $mk" >&2; exit 1; }
printf '%s\n' "$out"
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test-packageinfo-names.sh && echo OK`
Expected: `OK`。

- [ ] **Step 5: Commit**

```bash
git add scripts/packageinfo-names.sh tests/fixtures/packageinfo.txt tests/test-packageinfo-names.sh
git commit -m "feat: derive a package's subpackage names from tmp/.packageinfo" -m "This is buildroot's own source-to-binary mapping, so i18n subpackages are collected exactly instead of by filename glob.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: pkg-meta.sh

**Files:**
- Create: `scripts/pkg-meta.sh`
- Test: `tests/test-pkg-meta.sh`

**Interfaces:**
- Produces: `scripts/pkg-meta.sh <file.apk|file.ipk>` 输出一行 `name<TAB>version<TAB>arch`。apk 用 `$APK`（默认 `apk`）的 `adbdump`；ipk 解 control。

- [ ] **Step 1: 写失败测试（ipk 真实构造；apk 用假 apk 命令）**

```bash
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

mkdir -p "$tmp/bin"; cat > "$tmp/bin/apk" <<'EOF'
#!/usr/bin/env bash
printf '  name: luci-mod-x\n  version: 26.255.1~abc\n  arch: noarch\n  depends: # 1 items\n'
EOF
chmod +x "$tmp/bin/apk"
got=$(APK="$tmp/bin/apk" bash scripts/pkg-meta.sh "$tmp/luci-mod-x-26.255.1~abc.apk")
[ "$got" = "$(printf 'luci-mod-x\t26.255.1~abc\tnoarch')" ] || { echo "apk: $got"; exit 1; }
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test-pkg-meta.sh`
Expected: 退出码非 0。

- [ ] **Step 3: 实现**

```bash
#!/usr/bin/env bash
set -euo pipefail
f=$1
case "$f" in
  *.apk)
    "${APK:-apk}" adbdump "$f" | awk '
      /^  name: /    && !n { n=$2 }
      /^  version: / && !v { v=$2 }
      /^  arch: /    && !a { a=$2 }
      END { if (!n||!v||!a) exit 1; printf "%s\t%s\t%s\n", n, v, a }' ;;
  *.ipk)
    tar -xzOf "$f" ./control.tar.gz | tar -xzOf - ./control | awk '
      /^Package: /      { n=$2 }
      /^Version: /      { v=$2 }
      /^Architecture: / { a=$2 }
      END { if (!n||!v||!a) exit 1; printf "%s\t%s\t%s\n", n, v, a }' ;;
  *) echo "pkg-meta: unsupported file $f" >&2; exit 1 ;;
esac
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test-pkg-meta.sh && echo OK`
Expected: `OK`。

- [ ] **Step 5: Commit**

```bash
git add scripts/pkg-meta.sh tests/test-pkg-meta.sh
git commit -m "feat: read name, version and arch from a built package" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: compile.sh（带 -j1 重试）

**Files:**
- Create: `scripts/compile.sh`
- Test: `tests/test-compile-retry.sh`

**Interfaces:**
- Produces: `scripts/compile.sh <pkg> <log-dir>`。用 `${MAKE:-make}`；先 `-j$(nproc)`，失败则 `-j1 V=s` 输出到 `<log-dir>/<pkg>.log` 再试一次；最终失败退出码非 0 并打印日志尾部。

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/make" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$MAKE_CALLS"
n=$(wc -l < "$MAKE_CALLS")
[ "$n" -ge "${FAIL_UNTIL:-0}" ] || { echo "boom"; exit 2; }
echo built
EOF
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
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test-compile-retry.sh`
Expected: 退出码非 0。

- [ ] **Step 3: 实现**

```bash
#!/usr/bin/env bash
set -euo pipefail
pkg=$1 logdir=$2
mkdir -p "$logdir"
make_cmd=${MAKE:-make}
jobs=$(nproc 2>/dev/null || echo 2)
if $make_cmd "package/$pkg/compile" -j"$jobs" > "$logdir/$pkg.log" 2>&1; then
  exit 0
fi
echo "compile: $pkg failed at -j$jobs, retrying with -j1 V=s" >&2
if $make_cmd "package/$pkg/compile" -j1 V=s > "$logdir/$pkg.log" 2>&1; then
  exit 0
fi
echo "compile: $pkg failed" >&2
tail -n 60 "$logdir/$pkg.log" >&2
exit 1
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test-compile-retry.sh && echo OK`
Expected: `OK`。

- [ ] **Step 5: Commit**

```bash
git add scripts/compile.sh tests/test-compile-retry.sh
git commit -m "feat: compile one package with a single -j1 retry" -m "luci-mod-dashboard failed under -j4 and passed under -j1 in the local SDK run; the retry also leaves a readable V=s log when a build genuinely breaks.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: collect.sh

**Files:**
- Create: `scripts/collect.sh`
- Test: `tests/test-collect.sh`

**Interfaces:**
- Consumes: `scripts/packageinfo-names.sh`（Task 3）、`scripts/pkg-meta.sh`（Task 4，通过 `$PKG_META` 可替换）。
- Produces: `scripts/collect.sh <spec.json> <feed_name> <arch> <pkg_type> <sdk> <sdk-root> <out>`。
  把每个规格的全部子包文件复制到 `<out>/`，校验架构，写 `<out>/build-info.json`：
  ```json
  {"sdk":"25.12.5","arch":"x86_64","pkg_type":"apk",
   "packages":[{"pkg":"luci-mod-dashboard","kind":"feed","ref":"<sha>","declared_arch":"all",
     "files":[{"file":"luci-mod-dashboard-26.255.27927~75b7b1c.apk","name":"luci-mod-dashboard",
               "version":"26.255.27927~75b7b1c","arch":"noarch","size":13040,"sha256":"..."}]}]}
  ```

- [ ] **Step 1: 写失败测试（夹具 SDK 树 + 假 pkg-meta）**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sdk="$tmp/sdk"; mkdir -p "$sdk/tmp" "$sdk/bin/packages/x86_64/eamonxg" "$sdk/bin/packages/x86_64/luci"
cp tests/fixtures/packageinfo.txt "$sdk/tmp/.packageinfo"
for f in luci-mod-dashboard-26.255.1~abc.apk luci-i18n-dashboard-de-26.255.1~abc.apk luci-i18n-dashboard-zh-cn-26.255.1~abc.apk luci-mod-dashboard-extra-1.apk; do echo "$f" > "$sdk/bin/packages/x86_64/luci/$f"; done
echo a > "$sdk/bin/packages/x86_64/eamonxg/luci-theme-aurora-1.3.1-r2.apk"

cat > "$tmp/meta" <<'EOF'
#!/usr/bin/env bash
b=$(basename "$1")
case "$b" in
  luci-theme-aurora-*)   printf 'luci-theme-aurora\t1.3.1-r2\tnoarch\n' ;;
  luci-mod-dashboard-26*) printf 'luci-mod-dashboard\t26.255.1~abc\tnoarch\n' ;;
  luci-i18n-dashboard-de-*) printf 'luci-i18n-dashboard-de\t26.255.1~abc\tnoarch\n' ;;
  luci-i18n-dashboard-zh-cn-*) printf 'luci-i18n-dashboard-zh-cn\t26.255.1~abc\tnoarch\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/meta"
sha=0123456789abcdef0123456789abcdef01234567
cat > "$tmp/spec.json" <<EOF
[{"pkg":"luci-theme-aurora","kind":"local","path":".","arch":"all","langs":[]},
 {"pkg":"luci-mod-dashboard","kind":"feed","url":"u","ref":"$sha","feed":"luci","arch":"all","langs":["zh-cn"]}]
EOF
PKG_META="$tmp/meta" bash scripts/collect.sh "$tmp/spec.json" eamonxg x86_64 apk 25.12.5 "$sdk" "$tmp/out"

[ "$(ls "$tmp/out"/*.apk | wc -l | tr -d ' ')" = 4 ] || { echo "expected 4 files, got: $(ls "$tmp/out")"; exit 1; }
[ ! -e "$tmp/out/luci-mod-dashboard-extra-1.apk" ] || { echo "prefix collision"; exit 1; }
bi="$tmp/out/build-info.json"
[ "$(jq -r .pkg_type "$bi")" = apk ] || { echo "pkg_type"; exit 1; }
[ "$(jq -r '.packages|length' "$bi")" = 2 ] || { echo "packages"; exit 1; }
[ "$(jq -r '.packages[1].files|length' "$bi")" = 3 ] || { echo "dashboard files"; exit 1; }
[ "$(jq -r '.packages[1].ref' "$bi")" = "$sha" ] || { echo "ref"; exit 1; }
[ "$(jq -r '.packages[0].files[0].version' "$bi")" = "1.3.1-r2" ] || { echo "version"; exit 1; }
[ "$(jq -r '.packages[0].files[0].sha256' "$bi")" = "$(shasum -a 256 "$tmp/out/luci-theme-aurora-1.3.1-r2.apk" | cut -d' ' -f1)" ] || { echo "sha"; exit 1; }

cat > "$tmp/spec2.json" <<EOF
[{"pkg":"luci-theme-aurora","kind":"local","path":".","arch":["x86_64"],"langs":[]}]
EOF
if PKG_META="$tmp/meta" bash scripts/collect.sh "$tmp/spec2.json" eamonxg x86_64 apk 25.12.5 "$sdk" "$tmp/out2" 2>"$tmp/err"; then echo "arch mismatch must fail"; exit 1; fi
grep -q 'luci-theme-aurora' "$tmp/err" || { echo "error must name the package"; exit 1; }
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test-collect.sh`
Expected: 退出码非 0。

- [ ] **Step 3: 实现**

```bash
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
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test-collect.sh && echo OK`
Expected: `OK`。

- [ ] **Step 5: Commit**

```bash
git add scripts/collect.sh tests/test-collect.sh
git commit -m "feat: collect built subpackages by name and verify their arch" -m "A package declared noarch that comes out arch-tagged (or the reverse) fails the build here, so the declaration in the feed config cannot drift from what the Makefile actually produces.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: entrypoint.sh + action.yml（构建核心）

**Files:**
- Create: `entrypoint.sh`
- Modify: `action.yml`（整体替换为 v2）
- Test: 集成（Task 9）；本任务只做静态检查 `bash -n`。

**Interfaces:**
- Consumes: Task 1–6 的脚本。
- Produces: action 输入 `sdk`、`arch`、`packages`、`feed_name`、`out`、`image`、`index_tools`；
  输出 `pkg_type`、`arch`、`out`；目录 `<out>/` 含包文件、`build-info.json`、`logs/`、
  `.tools/`（`apk`、`usign`、`ipkg-make-index.sh`、`make-index-json.py`）。

- [ ] **Step 1: 写 entrypoint.sh**

```bash
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

langs=$(jq -r '[.[].langs[]] | unique | .[]' "$WORK/spec.json")
install="luci-base"
for l in $langs; do install="$install luci-i18n-base-$l"; done
# shellcheck disable=SC2086
./scripts/feeds install -f $install
jq -c '.[]' "$WORK/spec.json" | while read -r e; do
  pkg=$(jq -r .pkg <<<"$e")
  if [ "$(jq -r .kind <<<"$e")" = feed ]; then
    ./scripts/feeds install -f -p "$(jq -r .feed <<<"$e")" "$pkg"
  else
    ./scripts/feeds install -f -p "$FEED_NAME" "$pkg"
  fi
done

{ [ -z "${USIGN_KEY:-}${APK_KEY:-}" ] || echo "CONFIG_SIGNED_PACKAGES=y"
  for l in $langs; do
    case "$l" in zh-cn) sym=zh_Hans ;; zh-tw) sym=zh_Hant ;; *) sym=$l ;; esac
    echo "CONFIG_LUCI_LANG_$sym=y"
  done; } >> .config
make defconfig >/dev/null

if grep -q '^CONFIG_USE_APK=y' .config; then PKG_TYPE=apk; else PKG_TYPE=ipk; fi
export APK=/builder/staging_dir/host/bin/apk

jq -r '.[].pkg' "$WORK/spec.json" | while read -r pkg; do
  echo "::group::compile $pkg"
  "$S/compile.sh" "$pkg" "$OUT/logs"
  echo "::endgroup::"
done

"$S/collect.sh" "$WORK/spec.json" "$FEED_NAME" "$ARCH" "$PKG_TYPE" "$SDK" /builder "$OUT"

if [ "${INDEX_TOOLS:-true}" = true ]; then
  mkdir -p "$OUT/.tools"
  cp staging_dir/host/bin/.apk.bin "$OUT/.tools/apk"
  cp staging_dir/host/bin/.usign.bin "$OUT/.tools/usign"
  cp scripts/ipkg-make-index.sh scripts/make-index-json.py "$OUT/.tools/"
  chmod +x "$OUT/.tools/"*
fi
echo "pkg_type=$PKG_TYPE" > "$OUT/.pkg_type"
```

- [ ] **Step 2: 写 action.yml（整体替换）**

```yaml
name: Build LuCI packages
description: Build a set of packages in an official OpenWrt SDK image and emit a directory with metadata
inputs:
  sdk:
    description: OpenWrt SDK version, e.g. 25.12.5, 24.10.4 or main
    required: true
  arch:
    description: Package architecture, e.g. x86_64 or aarch64_cortex-a53
    required: false
    default: x86_64
  packages:
    description: JSON array of package specs (pkg + path|repo[+ref][+feed], arch, langs)
    required: true
  feed_name:
    description: Name of the src-link feed the local/repo packages are built from
    required: false
    default: eamonxg
  out:
    description: Directory (relative to the workspace) to place the built packages in
    required: false
    default: out
  image:
    description: SDK image repository
    required: false
    default: ghcr.io/openwrt/sdk
  index_tools:
    description: Also export apk/usign and the index scripts under <out>/.tools
    required: false
    default: "true"
outputs:
  pkg_type:
    description: apk or ipk, as decided by the SDK
    value: ${{ steps.done.outputs.pkg_type }}
  arch:
    description: The architecture that was built
    value: ${{ inputs.arch }}
  out:
    description: The output directory
    value: ${{ inputs.out }}
runs:
  using: composite
  steps:
    - name: Validate and materialise sources
      shell: bash
      env:
        PACKAGES: ${{ inputs.packages }}
      run: |
        set -euo pipefail
        A="${{ github.action_path }}"
        WORK="$RUNNER_TEMP/blp-work"; rm -rf "$WORK"; mkdir -p "$WORK"
        printf '%s' "$PACKAGES" | bash "$A/scripts/validate-spec.sh" > "$WORK/spec.norm.json"
        bash "$A/scripts/materialize.sh" "$WORK/spec.norm.json" "$WORK"
        echo "WORK=$WORK" >> "$GITHUB_ENV"

    - name: Build in ${{ inputs.image }}:${{ inputs.arch }}-${{ inputs.sdk }}
      shell: bash
      env:
        USIGN_KEY: ${{ env.USIGN_KEY }}
        APK_KEY: ${{ env.APK_KEY }}
      run: |
        set -euo pipefail
        A="${{ github.action_path }}"
        IMG="${{ inputs.image }}:${{ inputs.arch }}-${{ inputs.sdk }}"
        docker pull -q "$IMG"
        sudo chown -R 1000:1000 "$WORK"
        docker run --rm \
          -v "$WORK:/work" \
          -v "$A/entrypoint.sh:/entrypoint.sh:ro" \
          -v "$A/scripts:/scripts:ro" \
          -e ARCH="${{ inputs.arch }}" -e SDK="${{ inputs.sdk }}" \
          -e FEED_NAME="${{ inputs.feed_name }}" -e INDEX_TOOLS="${{ inputs.index_tools }}" \
          -e USIGN_KEY -e APK_KEY \
          "$IMG" bash /entrypoint.sh
        sudo chown -R "$(id -u):$(id -g)" "$WORK"

    - name: Stage output
      id: done
      shell: bash
      run: |
        set -euo pipefail
        rm -rf "${{ inputs.out }}"; mkdir -p "$(dirname "${{ inputs.out }}")"
        cp -R "$WORK/out" "${{ inputs.out }}"
        pkg_type=$(sed 's/^pkg_type=//' "${{ inputs.out }}/.pkg_type")
        echo "pkg_type=$pkg_type" >> "$GITHUB_OUTPUT"
        echo "== ${{ inputs.out }} =="; ls -la "${{ inputs.out }}"
```

- [ ] **Step 3: 静态检查**

Run: `bash -n entrypoint.sh && for s in scripts/*.sh; do bash -n "$s"; done && echo SYNTAX_OK`
Expected: `SYNTAX_OK`。

- [ ] **Step 4: 本地容器冒烟（macOS 上用 docker 卷保证大小写敏感）**

```bash
cd /Users/eamon/Developer/github/luci-theme/build-luci-package
docker volume create blp-work >/dev/null
sha=$(git ls-remote https://github.com/eamonxg/luci-theme-aurora.git HEAD | cut -f1)
printf '[{"pkg":"luci-theme-aurora","repo":"eamonxg/luci-theme-aurora","ref":"%s"}]' "$sha" \
  | bash scripts/validate-spec.sh > /tmp/spec.json
rm -rf /tmp/blp && bash scripts/materialize.sh /tmp/spec.json /tmp/blp
docker run --rm --platform linux/amd64 --user root -v blp-work:/work alpine sh -c 'rm -rf /work/*'
docker run --rm --platform linux/amd64 --user root -v blp-work:/work -v /tmp/blp:/src:ro alpine \
  sh -c 'cp -R /src/. /work/ && chown -R 1000:1000 /work'
docker run --rm --platform linux/amd64 --user 1000:1000 -v blp-work:/work \
  -v "$PWD/entrypoint.sh:/entrypoint.sh:ro" -v "$PWD/scripts:/scripts:ro" \
  -e ARCH=x86_64 -e SDK=25.12.5 -e FEED_NAME=eamonxg -e INDEX_TOOLS=true \
  ghcr.io/openwrt/sdk:x86_64-25.12.5 bash /entrypoint.sh
docker run --rm --platform linux/amd64 -v blp-work:/work alpine sh -c 'ls -la /work/out /work/out/.tools; cat /work/out/build-info.json'
```
Expected: `out/` 里有 `luci-theme-aurora-<ver>.apk`、`build-info.json`（`pkg_type: apk`，一个文件条目 `arch: noarch`），`.tools/` 四个文件。
若 `ghcr.io/openwrt/sdk:x86_64-25.12.5` 拉不到，改用 `openwrt/sdk:x86_64-25.12.5` 并把 action 的 `image` 默认值改成 `openwrt/sdk`，在 commit body 里记录原因。

- [ ] **Step 5: Commit**

```bash
git add entrypoint.sh action.yml
git commit -m "feat!: rebuild the action around official SDK images" -m "One composite action builds a list of packages inside ghcr.io/openwrt/sdk:<arch>-<sdk> with our own entrypoint. The package format is read from the SDK instead of being an input, upstream feeds can be overridden with a fork at a pinned commit, and the output is a directory with build-info.json describing exactly what was produced. prep_script, artifact_paths and pkg_type are gone; release publishing moves to release/.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: release/action.yml

**Files:**
- Create: `release/action.yml`

**Interfaces:**
- Produces: 输入 `name`、`files`（多行 glob）、`release`（"true"/"false"）、`release_tag`、`body_repo`、`body_path`。
  tag 构建或 `release=true` 时用 softprops/action-gh-release@v2 创建或更新 Release。语义与 v1 尾部一致。

- [ ] **Step 1: 写 release/action.yml**

```yaml
name: Publish LuCI package release
description: Create or update a GitHub Release with the built package files
inputs:
  name:
    description: Release name prefix, usually the package name
    required: true
  files:
    description: Newline-separated file globs to attach
    required: true
  release:
    description: Set to "true" to publish when not running on a tag
    required: false
    default: "false"
  release_tag:
    description: Tag to create or update when release is "true" outside tag builds
    required: false
    default: ""
  body_repo:
    description: Repo holding the release body markdown (e.g. eamonxg/assets); empty = local file
    required: false
    default: ""
  body_path:
    description: Path of the body markdown, relative to body_repo or to the workspace
    required: false
    default: ""
runs:
  using: composite
  steps:
    - name: Resolve release body
      id: body
      if: ${{ github.ref_type == 'tag' || inputs.release == 'true' }}
      shell: bash
      env:
        GH_TOKEN: ${{ github.token }}
      run: |
        set -euo pipefail
        path="${{ inputs.body_path }}"; repo="${{ inputs.body_repo }}"
        empty="$GITHUB_WORKSPACE/.release-body-empty"
        if [ -n "$repo" ] && [ -n "$path" ]; then
          out="$GITHUB_WORKSPACE/.release-body.md"
          if gh api "repos/${repo}/contents/${path}" --jq '.content' | base64 -d > "$out" 2>/dev/null && [ -s "$out" ]; then
            echo "path=$out" >> "$GITHUB_OUTPUT"; exit 0
          fi
          echo "Warning: could not fetch '${path}' from '${repo}', using empty body" >&2
        elif [ -n "$path" ] && [ -f "$path" ]; then
          echo "path=$path" >> "$GITHUB_OUTPUT"; exit 0
        fi
        : > "$empty"; echo "path=$empty" >> "$GITHUB_OUTPUT"

    - name: Resolve release target
      id: target
      if: ${{ github.ref_type == 'tag' || inputs.release == 'true' }}
      shell: bash
      run: |
        set -euo pipefail
        if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
          tag="$GITHUB_REF_NAME"
        else
          tag="$(printf '%s' "${{ inputs.release_tag }}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [ -n "$tag" ] || { echo "release_tag is required when release is true outside tag builds" >&2; exit 1; }
        fi
        echo "tag_name=$tag" >> "$GITHUB_OUTPUT"
        echo "target_commitish=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"

    - name: Release
      if: ${{ github.ref_type == 'tag' || inputs.release == 'true' }}
      uses: softprops/action-gh-release@v2
      with:
        name: ${{ inputs.name }}-${{ steps.target.outputs.tag_name }}
        tag_name: ${{ steps.target.outputs.tag_name }}
        target_commitish: ${{ steps.target.outputs.target_commitish }}
        body_path: ${{ steps.body.outputs.path }}
        draft: false
        prerelease: false
        files: ${{ inputs.files }}
```

- [ ] **Step 2: 静态检查**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('release/action.yml'))" && echo YAML_OK`
Expected: `YAML_OK`（若无 PyYAML，用 `ruby -ryaml -e 'YAML.load_file("release/action.yml")'`）。

- [ ] **Step 3: Commit**

```bash
git add release/action.yml
git commit -m "feat: split GitHub Release publishing into release/" -m "Same body-resolution and tag-resolution rules as the v1 tail, so callers keep their changelog repos and release_tag semantics.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: 集成测试 workflow + 架构夹具包

**Files:**
- Create: `tests/fixtures/hello-arch/Makefile`
- Create: `tests/fixtures/hello-arch/src/hello.c`
- Modify: `.github/workflows/test-action.yml`（整体替换）

**Interfaces:**
- Consumes: Task 7 的 action。
- Produces: CI 证据：noarch 双 SDK、feed 覆盖版本等于 findrev、架构包双架构、声明错误必失败。

- [ ] **Step 1: 写最小架构包夹具**

`tests/fixtures/hello-arch/Makefile`：
```make
include $(TOPDIR)/rules.mk

PKG_NAME:=hello-arch
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/hello-arch
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Tiny compiled program used to test arch-specific builds
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -o $(PKG_BUILD_DIR)/hello-arch $(PKG_BUILD_DIR)/hello.c
endef

define Package/hello-arch/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/hello-arch $(1)/usr/bin/
endef

$(eval $(call BuildPackage,hello-arch))
```

`tests/fixtures/hello-arch/src/hello.c`：
```c
#include <stdio.h>
int main(void) { puts("hello-arch"); return 0; }
```

- [ ] **Step 2: 写 workflow**

```yaml
name: Test build action

on:
  workflow_dispatch:
  push:
    branches: [v2, master]
    paths: [action.yml, entrypoint.sh, scripts/**, release/**, tests/**, .github/workflows/test-action.yml]

permissions:
  contents: read

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - run: bash tests/run.sh

  noarch:
    runs-on: ubuntu-latest
    needs: unit
    strategy:
      fail-fast: false
      matrix:
        sdk: ["24.10.4", "25.12.5"]
    steps:
      - uses: actions/checkout@v6
      - uses: actions/checkout@v6
        with:
          repository: eamonxg/luci-theme-aurora
          path: aurora
          fetch-depth: 0
      - id: build
        uses: ./
        with:
          sdk: ${{ matrix.sdk }}
          packages: '[{"pkg":"luci-theme-aurora","path":"aurora"}]'
      - run: |
          set -euo pipefail
          ls out
          test -f out/build-info.json
          [ "$(jq -r '.packages[0].files|length' out/build-info.json)" = 1 ]
          case "${{ matrix.sdk }}" in 24.*) want=ipk ;; *) want=apk ;; esac
          [ "${{ steps.build.outputs.pkg_type }}" = "$want" ]
          test -x out/.tools/apk && test -x out/.tools/usign

  feed-override:
    runs-on: ubuntu-latest
    needs: unit
    steps:
      - uses: actions/checkout@v6
      - id: build
        uses: ./
        with:
          sdk: "25.12.5"
          packages: '[{"pkg":"luci-mod-dashboard","repo":"eamonxg/luci","ref":"75b7b1cc0186d4a1d0e0b0e29656126ebda0e898","feed":"luci","langs":["zh-cn"]}]'
      - run: |
          set -euo pipefail
          git clone -q https://github.com/eamonxg/luci.git luci && git -C luci checkout -q 75b7b1cc0186d4a1d0e0b0e29656126ebda0e898
          set -- $(git -C luci log -1 --format='%ct %h' --abbrev=7 -- modules/luci-mod-dashboard ':(exclude)po')
          want=$(printf '%s.%05d~%s' "$(date --utc --date="@$1" +%y.%j)" "$(($1 % 86400))" "$2")
          got=$(jq -r '.packages[0].files[] | select(.name=="luci-mod-dashboard") | .version' out/build-info.json)
          echo "want=$want got=$got"; [ "$got" = "$want" ]
          [ "$(jq -r '.packages[0].files|length' out/build-info.json)" -ge 2 ]

  arch:
    runs-on: ubuntu-latest
    needs: unit
    strategy:
      fail-fast: false
      matrix:
        arch: [x86_64, aarch64_cortex-a53]
    steps:
      - uses: actions/checkout@v6
      - uses: ./
        with:
          sdk: "25.12.5"
          arch: ${{ matrix.arch }}
          packages: '[{"pkg":"hello-arch","path":"tests/fixtures/hello-arch","arch":"any"}]'
      - run: |
          set -euo pipefail
          [ "$(jq -r '.packages[0].files[0].arch' out/build-info.json)" = "${{ matrix.arch }}" ]

  arch-declared-wrong:
    runs-on: ubuntu-latest
    needs: unit
    steps:
      - uses: actions/checkout@v6
      - id: build
        continue-on-error: true
        uses: ./
        with:
          sdk: "25.12.5"
          packages: '[{"pkg":"hello-arch","path":"tests/fixtures/hello-arch"}]'
      - run: |
          [ "${{ steps.build.outcome }}" = failure ] || { echo "a noarch declaration on an arch package must fail the build"; exit 1; }
```

- [ ] **Step 3: 本地跑单元测试全量**

Run: `bash tests/run.sh`
Expected: 全部 PASS。

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/hello-arch .github/workflows/test-action.yml
git commit -m "test: integration matrix for noarch, feed override and arch builds" -m "The feed-override case asserts the version string equals luci.mk's findrev formula computed from the fork's git, which proves the pinned-commit clone keeps history. The arch cases use a ten-line C program so the arch path is exercised without depending on any upstream package.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 5: 推送 v2 分支并观察 CI（需用户确认后再 push）**

等用户确认后：`git push -u origin v2`，然后 `gh run watch` 直到四个 job 全绿。任一失败按 systematic-debugging 处理，不得改测试断言来绿。

---

### Task 10: README

**Files:**
- Modify: `README.md`（整体重写）

- [ ] **Step 1: 写 README**

```markdown
# build-luci-package

Build LuCI packages inside the official OpenWrt SDK images and get back a directory that says exactly what was built.

## Build

    - uses: eamonxg/build-luci-package@v2
      with:
        sdk: "25.12.5"            # 24.10.4 → ipk, 25.12.5 / main → apk (decided by the SDK)
        arch: x86_64              # any package arch the SDK publishes, e.g. aarch64_cortex-a53
        packages: '[{"pkg":"luci-theme-aurora","path":"."}]'
      env:
        USIGN_KEY: ${{ secrets.USIGN_PRIVATE_KEY }}   # optional, signs ipk output
        APK_KEY:   ${{ secrets.APK_PRIVATE_KEY }}     # optional, signs apk output

Outputs `pkg_type`, `arch`, `out`. The `out/` directory holds the package files, `build-info.json`
(files, versions, arches, sha256 per package), `logs/`, and `.tools/` (apk, usign and the index scripts
from this SDK, for indexing outside the container).

## Package spec

| key   | meaning |
| ----- | ------- |
| pkg   | package name (required) |
| path  | directory on the runner holding the package (its root has the Makefile) |
| repo  | `owner/name` or git URL; requires `ref` as a 40-char sha |
| feed  | with `repo`: override this upstream feed (base, packages, luci, routing, telephony, video) with `repo@ref` and build `pkg` from it. Use this for packages that live inside a monorepo. |
| arch  | `"all"` (default, must build noarch), `"any"` (arch-specific), or a list of arches |
| langs | languages whose `luci-i18n-base-*` are installed and enabled before the build |

Exactly one of `path` / `repo`. The build fails if a package's real architecture disagrees with `arch`.

## Release

    - uses: eamonxg/build-luci-package/release@v2
      with:
        name: luci-theme-aurora
        files: out/*.apk
        body_repo: eamonxg/assets
        body_path: aurora/docs/theme/changelog/${{ github.ref_name }}.md

Publishes on tag builds, or when `release: "true"` with `release_tag`.

## Design

The feed pipeline that consumes this action, and the reasons behind its shape, are described in
openwrt-cloud's feed infra v2 design document.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: describe the v2 build and release actions" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## 自检记录

- 覆盖：§1 接口（Task 7）、来源三种（Task 1、2、7）、feeds.conf 覆盖（Task 7）、编译重试（Task 5）、
  .packageinfo 收集与架构校验（Task 3、4、6）、工具包导出（Task 7）、release 拆分（Task 8）、
  §8 集成用例四种（Task 9）、README（Task 10）。
- 未覆盖但属计划 B：索引、manifest、站点、验证器。属计划 C：调用方迁移、dashboard 条目。
- 名称一致性：`validate-spec.sh` 输出字段 `pkg/kind/path/url/ref/feed/arch/langs`，
  `materialize.sh`、`collect.sh`、`entrypoint.sh` 均按此消费；`collect.sh` 参数顺序
  `<spec> <feed_name> <arch> <pkg_type> <sdk> <root> <out>` 与 entrypoint 调用一致。
