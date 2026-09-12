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
