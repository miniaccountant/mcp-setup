#!/usr/bin/env bash
# oauth-metadata-check.sh — do the two addresses this repo publishes agree?
#
# server.json tells every registry and every client to connect to
# `remotes[].url`. The server at that URL answers 401 and points, through
# `WWW-Authenticate: Bearer resource_metadata=…`, at its own OAuth 2.0 Protected
# Resource Metadata document. RFC 9728 §3.3 is explicit about what the client
# must then do, for exactly this case — a metadata URL learned from that header:
#
#   "the `resource` value returned MUST be identical to the URL that the client
#    used to make the request" … "If these values are not identical, the data
#    contained in the response MUST NOT be used."
#
# So if the document names a different URL, a conforming client throws it away
# and never learns where the authorization server is. It fails BEFORE the
# sign-in screen rather than at it, which is why this is invisible to every
# other check in this repository: the schema is valid, the registry entry is
# published, the endpoint is up, and the quickstart still cannot complete.
#
# The MCP authorization spec (2025-06-18) closes the lenient path as well: a
# client MUST send the RFC 8707 `resource` parameter and it MUST be the
# canonical URI of the MCP server, aligned with RFC 9728's `resource`. A client
# that swallows the mismatch therefore asks for a token audienced to the wrong
# resource, and the server — which MUST validate that tokens were issued for it
# — has to reject it.
#
# WARN by default, ERROR on the weekly schedule, the same shape as
# registry-status.sh's DRIFT_IS_ERROR: a server-side field is not something a
# pull request can fix, so blocking every PR on it would only train people to
# ignore the job. The weekly run is the nag.
#
#   STRICT=true  -> a mismatch exits 1
#   (unset)      -> a mismatch warns and exits 0
#
# A check that could not run exits 0 with "COULD NOT CHECK" in either mode and
# never reports a mismatch it did not observe: an unreadable document compared
# against the endpoint would otherwise produce a confident fault report about
# bytes nobody read.

set -uo pipefail
STRICT="${STRICT:-false}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

warn()  { printf '::warning title=OAuth metadata::%s\n' "$1"; }
fatal() { printf '::error title=OAuth metadata::%s\n' "$1"; }

blind() {
  printf 'COULD NOT CHECK — %s\n' "$1"
  printf 'Not a verdict about the server. Nothing is concluded.\n'
  exit 0
}

ENDPOINT=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
r=[x.get("url") for x in (d.get("remotes") or []) if x.get("url")]
print(r[0] if r else "")
' "$ROOT/server.json" 2>/dev/null)

[ -n "$ENDPOINT" ] || blind "server.json declares no remotes[].url, so there is no endpoint to check"
printf 'server.json endpoint : %s\n' "$ENDPOINT"

# --- positive control: is that URL really an MCP server behind OAuth? --------
# Without this, a proxy, a WAF or a moved endpoint would be compared against
# server.json and reported as our fault.
hdrs=$(curl -s -D - -o /dev/null --max-time 30 -X POST "$ENDPOINT" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"oauth-metadata-check","version":"1"}}}' \
        -w '%{http_code}' 2>/dev/null)
status=$(printf '%s' "$hdrs" | tail -n1)

[ -n "$status" ] && [ "$status" != "000" ] || blind "no response from $ENDPOINT"
if [ "$status" != "401" ]; then
  blind "the endpoint answered $status, not 401 — either it is not protected, or this is not the MCP server; nothing below would be about it"
fi

META_URL=$(printf '%s' "$hdrs" | tr -d '\r' | sed -n 's/.*resource_metadata="\([^"]*\)".*/\1/p' | head -n1)
[ -n "$META_URL" ] || blind "the 401 carries no WWW-Authenticate resource_metadata parameter (the MCP spec requires one), so there is no document to read"
printf 'metadata document   : %s\n' "$META_URL"

got=$(curl -s --max-time 30 -w '\n%{http_code}' "$META_URL" 2>/dev/null)
mcode=$(printf '%s' "$got" | tail -n1)
body=$(printf '%s' "$got" | sed '$d')
[ "$mcode" = "200" ] && [ -n "$body" ] || blind "HTTP ${mcode:-000} / empty body from the metadata document"

parsed=$(printf '%s' "$body" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(3)
if not isinstance(d,dict): sys.exit(3)
print(d.get("resource","\x00MISSING"))
print(",".join(d.get("authorization_servers") or []))
' 2>/dev/null) || blind "the metadata document is not a JSON object — an error page or an interstitial"
[ -n "$parsed" ] || blind "the metadata document parsed to nothing"

RES=$(printf '%s' "$parsed" | sed -n 1p)
AS=$(printf '%s' "$parsed" | sed -n 2p)
RC=0
note() { if [ "$STRICT" = "true" ]; then fatal "$1"; RC=1; else warn "$1"; fi; }

if [ "$RES" = $'\x00MISSING' ]; then
  note "the metadata document has no \`resource\` field. RFC 9728 §2 makes it REQUIRED, so a client has nothing to validate and must discard the document."
elif [ "$RES" = "$ENDPOINT" ]; then
  printf 'resource            : %s — identical to the endpoint. OK\n' "$RES"
else
  note "the metadata document declares resource=\"$RES\" but server.json publishes \"$ENDPOINT\". RFC 9728 §3.3: a conforming client MUST NOT use this document, so the quickstart fails before the sign-in screen. Fix the \`resource\` field on the server to be the URL clients actually request."
fi

if [ -z "$AS" ]; then
  note "\`authorization_servers\` is empty or absent; the MCP spec requires at least one."
else
  printf 'authorization_servers: %s\n' "$AS"
fi

if [ "$RC" = 0 ] && [ "$STRICT" != "true" ]; then
  printf '\nWarnings above are not fatal on a pull request: a server-side field is not\nsomething a PR can fix. The weekly scheduled run sets STRICT and fails.\n'
fi
exit $RC
