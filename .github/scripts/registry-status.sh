#!/usr/bin/env bash
# Compares server.json with what the MCP Registry already serves, so CI can tell
# "new version, publish it" from "already published" from "you forgot to bump".
#
#   .github/scripts/registry-status.sh [path/to/server.json]
#
# Prints key=value lines and, under GitHub Actions, appends them to $GITHUB_OUTPUT:
#   name     server name, e.g. dev.dudko/tabellum
#   version  server.json "version"
#   domain   the domain that owns the namespace (dev.dudko -> dudko.dev); DNS auth
#            is done against its apex TXT record
#   latest   latest version the registry serves for this name ("" if none)
#   state    new        - the registry has no such version: publishing will create it
#            published  - the registry serves this exact server.json already: no-op
#            conflict   - same version, different content: the version was not bumped
#
# For npm packages it also checks that packages[].version exists on npm and that
# its package.json carries "mcpName" equal to the server name (the registry refuses
# the publish otherwise), and reports when npm has a newer release than server.json.
#
# Exit status: 0 = fine, 1 = something to fix (conflict, version lower than the
# latest published one, npm release missing or without mcpName, or - with
# DRIFT_IS_ERROR=true - npm ahead of server.json), 2 = registry/npm unreachable.
set -euo pipefail

file=${1:-server.json}
registry=${MCP_REGISTRY_URL:-https://registry.modelcontextprotocol.io}
npm_registry=${NPM_REGISTRY_URL:-https://registry.npmjs.org}
drift_is_error=${DRIFT_IS_ERROR:-false}

err() { echo "::error file=$file::$*"; failed=1; }
warn() { echo "::warning file=$file::$*"; }
uri() { jq -rn --arg s "$1" '$s|@uri'; }
# true when $1 is a strictly higher version than $2
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

name=$(jq -er .name "$file")
version=$(jq -er .version "$file")
namespace=${name%%/*}
domain=$(tr . '\n' <<<"$namespace" | tac | paste -sd. -)
enc=$(uri "$name")

# --- the registry -------------------------------------------------------------
code=$(curl -sS -o "$tmp/latest.json" -w '%{http_code}' "$registry/v0/servers/$enc/versions/latest") || exit 2
case $code in
  200) latest=$(jq -r .server.version "$tmp/latest.json") ;;
  404) latest="" ;;
  *) echo "::error::$registry answered $code for $name"; exit 2 ;;
esac

code=$(curl -sS -o "$tmp/this.json" -w '%{http_code}' "$registry/v0/servers/$enc/versions/$(uri "$version")") || exit 2
case $code in
  200)
    if diff <(jq -S .server "$tmp/this.json") <(jq -S . "$file") >"$tmp/diff"; then
      state=published
      echo "::notice file=$file::$name@$version is already in the registry with exactly this content - nothing to publish."
    else
      state=conflict
      err "$name@$version is already in the registry with different content. Registry versions are immutable: bump \"version\" in server.json (latest published: ${latest:-none})."
      echo "--- registry  +++ server.json"; cat "$tmp/diff"
    fi ;;
  404)
    state=new
    if [ -n "$latest" ] && newer "$latest" "$version"; then
      err "version $version is lower than $latest, the latest one in the registry. Pick a version above $latest."
    else
      echo "::notice file=$file::$name@$version is not in the registry yet (latest: ${latest:-none}) - a publish will create it."
    fi ;;
  *) echo "::error::$registry answered $code for $name@$version"; exit 2 ;;
esac

# --- npm packages -------------------------------------------------------------
count=$(jq '[.packages[]? | select(.registryType == "npm")] | length' "$file")
for ((i = 0; i < count; i++)); do
  id=$(jq -r "[.packages[] | select(.registryType == \"npm\")][$i].identifier" "$file")
  pv=$(jq -r "[.packages[] | select(.registryType == \"npm\")][$i].version" "$file")
  code=$(curl -sS -o "$tmp/npm.json" -w '%{http_code}' "$npm_registry/$(uri "$id")") || exit 2
  [ "$code" = 200 ] || { echo "::error::$npm_registry answered $code for $id"; exit 2; }
  npm_latest=$(jq -r '."dist-tags".latest // empty' "$tmp/npm.json")
  if ! jq -e --arg v "$pv" '.versions[$v]' "$tmp/npm.json" >/dev/null; then
    err "npm has no $id@$pv. Release the package first, then point server.json at it (npm latest: ${npm_latest:-none})."
    continue
  fi
  mcp_name=$(jq -r --arg v "$pv" '.versions[$v].mcpName // empty' "$tmp/npm.json")
  if [ "$mcp_name" != "$name" ]; then
    if [ -n "$mcp_name" ]; then has="mcpName \"$mcp_name\""; else has="no mcpName"; fi
    err "$id@$pv has $has in its package.json; the registry requires \"mcpName\": \"$name\". Release a version that carries it and point server.json at that."
  fi
  if [ "$pv" != "$version" ]; then
    warn "server.json version $version differs from the npm package version $pv. Keep them equal: the server version is the package release."
  fi
  if [ -n "$npm_latest" ] && newer "$npm_latest" "$pv"; then
    msg="npm has $id@$npm_latest but server.json still points at $pv. Set both \"version\" and packages[].version to $npm_latest so the registry lists the current release."
    if [ "$drift_is_error" = true ]; then err "$msg"; else warn "$msg"; fi
  fi
done

out="name=$name
version=$version
domain=$domain
latest=$latest
state=$state"
echo "$out"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "$out" >>"$GITHUB_OUTPUT"
exit "$failed"
