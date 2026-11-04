#!/usr/bin/env bash
# Walks the OAuth discovery chain a real MCP client walks, from the URL this
# repository publishes, and fails when two of our own published addresses
# disagree. Every other check here asks whether a field is PRESENT; this one
# asks whether two fields AGREE, which is the gap that let a broken quickstart
# sit on the public surface while everything reported green.
#
#   .github/scripts/oauth-discovery-check.sh [path/to/server.json]
#
# What a client does, and therefore what this does, for every remotes[].url:
#
#   1. GET the endpoint with no token. Expect 401 and a WWW-Authenticate header
#      carrying resource_metadata="..." (RFC 9728 s5.1, MCP spec 2025-06-18).
#   2. GET that metadata document. RFC 9728 s3.3 on a document discovered this
#      way: "the `resource` value returned MUST be identical to the URL that the
#      client used to make the request ... If these values are not identical,
#      the data contained in the response MUST NOT be used."
#   3. So compare them. A mismatch is not cosmetic: a conforming client discards
#      the document, never learns which authorization server to use, and fails
#      BEFORE the sign-in screen. From outside, that is indistinguishable from
#      the server simply being behind OAuth - which is why it can hide for weeks.
#   4. Check the authorization_servers it names actually serve metadata, and
#      that each one's issuer matches the URL it was discovered at.
#
# Prints key=value lines; under GitHub Actions also annotates the file.
#
# Exit status:
#   0  checked, and our published addresses agree
#   1  they disagree, or the chain is broken in a way a client would trip over
#   2  COULD NOT LOOK - unreachable, a 5xx, or a non-JSON body where JSON was
#      required. Deliberately NOT 1: "I looked and found a mismatch" and "I
#      could not look" are different answers, and a check that collapses them
#      teaches the next reader to ignore it.
set -euo pipefail

file=${1:-server.json}
ua=${CHECK_USER_AGENT:-mcp-oauth-discovery-check}

err()  { echo "::error file=$file::$*"; failed=1; }
warn() { echo "::warning file=$file::$*"; }
out()  { echo "$1=$2"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >>"$GITHUB_OUTPUT"; return 0; }

failed=0
blind=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# fetch URL -> body in $tmp/body, status in $tmp/status, headers in $tmp/head
fetch() {
  local url=$1
  : >"$tmp/body"; : >"$tmp/head"
  if ! curl -sS --max-time 20 -A "$ua" -D "$tmp/head" -o "$tmp/body" \
            -w '%{http_code}' "$url" >"$tmp/status" 2>"$tmp/curlerr"; then
    echo "000" >"$tmp/status"
    return 1
  fi
  return 0
}

status() { cat "$tmp/status"; }

# the resource_metadata="..." parameter of a WWW-Authenticate: Bearer challenge
challenge_metadata() {
  tr -d '\r' <"$tmp/head" \
    | grep -i '^www-authenticate:' \
    | sed -n 's/.*resource_metadata="\([^"]*\)".*/\1/p' \
    | head -n1
}

json_or_blind() {
  local what=$1
  if ! jq -e . "$tmp/body" >/dev/null 2>&1; then
    warn "$what did not return JSON (status $(status)); COULD NOT LOOK, not a verdict"
    blind=1
    return 1
  fi
  return 0
}

jq -e . "$file" >/dev/null || { echo "::error::$file is not valid JSON"; exit 2; }

mapfile -t remotes < <(jq -r '(.remotes // [])[].url' "$file")
if [ "${#remotes[@]}" -eq 0 ]; then
  out remotes 0
  echo "no remotes[] in $file - nothing to check (a package-only server has no endpoint)"
  exit 0
fi
out remotes "${#remotes[@]}"

for endpoint in "${remotes[@]}"; do
  echo "--- $endpoint"

  if ! fetch "$endpoint"; then
    warn "$endpoint unreachable: $(tr -d '\n' <"$tmp/curlerr")"
    blind=1
    continue
  fi
  code=$(status)
  echo "  status $code"
  case "$code" in
    5*) warn "$endpoint answered $code; COULD NOT LOOK"; blind=1; continue ;;
  esac

  meta_url=$(challenge_metadata || true)
  if [ -z "$meta_url" ]; then
    if [ "$code" = "401" ] || [ "$code" = "403" ]; then
      err "$endpoint answered $code with no resource_metadata in WWW-Authenticate; a client cannot begin discovery (RFC 9728 s5.1)"
    else
      warn "$endpoint answered $code and offered no WWW-Authenticate challenge; not an OAuth-protected endpoint, or it is open"
    fi
    continue
  fi
  echo "  resource_metadata $meta_url"

  if ! fetch "$meta_url" || ! json_or_blind "the protected-resource document"; then
    [ "$(status)" = "000" ] && { warn "$meta_url unreachable"; blind=1; }
    continue
  fi

  resource=$(jq -r '.resource // empty' "$tmp/body")
  if [ -z "$resource" ]; then
    err "$meta_url has no \"resource\" field (RFC 9728 s3.1 requires it)"
  elif [ "$resource" != "$endpoint" ]; then
    err "DISAGREE: the protected-resource document declares resource=\"$resource\" but the published endpoint is \"$endpoint\". RFC 9728 s3.3: a client that discovered this document from the WWW-Authenticate challenge MUST NOT use it, so connection fails before the sign-in screen. Fix the server's \"resource\" field, or publish the address it names."
  else
    echo "  resource AGREES with the published endpoint"
  fi

  mapfile -t as < <(jq -r '(.authorization_servers // [])[]' "$tmp/body")
  if [ "${#as[@]}" -eq 0 ]; then
    err "$meta_url names no authorization_servers; a client has nowhere to send the user"
    continue
  fi
  for issuer in "${as[@]}"; do
    found=0
    for suffix in /.well-known/oauth-authorization-server /.well-known/openid-configuration; do
      if fetch "${issuer%/}$suffix" && [ "$(status)" = "200" ] && jq -e .issuer "$tmp/body" >/dev/null 2>&1; then
        declared=$(jq -r .issuer "$tmp/body")
        if [ "${declared%/}" != "${issuer%/}" ]; then
          err "authorization server $issuer serves metadata declaring issuer=\"$declared\"; RFC 8414 s3.3 requires them to be identical"
        fi
        for ep in authorization_endpoint token_endpoint; do
          jq -e --arg k "$ep" 'has($k)' "$tmp/body" >/dev/null || err "$issuer$suffix has no $ep"
        done
        echo "  authorization server $issuer OK ($suffix)"
        found=1
        break
      fi
    done
    [ "$found" = "1" ] || { warn "could not read metadata for authorization server $issuer at either well-known path"; blind=1; }
  done
done

if [ "$failed" = "1" ]; then
  out verdict disagree
  echo "FAIL - our own published addresses do not agree. A spec-conforming MCP client cannot connect."
  exit 1
fi
if [ "$blind" = "1" ]; then
  out verdict could-not-look
  echo "COULD NOT LOOK - part of the chain was unreachable. Nothing has been established either way."
  exit 2
fi
out verdict agree
echo "OK - the published endpoint, its protected-resource document and its authorization servers all agree."
