#!/usr/bin/env bash
# Chromium (the chrome-devtools MCP server) validates TLS against its own NSS
# store at ~/.pki/nssdb, not the system trust store. Behind this environment's
# TLS-inspecting egress proxy that means every HTTPS navigation dies with
# ERR_CERT_AUTHORITY_INVALID, even though curl, node and git are fine. Import
# the proxy CAs so the browser trusts what the rest of the container already
# trusts.
#
# Never fail session start over this: a browser that cannot reach HTTPS is bad,
# a session that will not start is worse. Every step below degrades to a no-op.
set -uo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

trust_proxy_cas_in_nssdb() {
  local nssdb="$HOME/.pki/nssdb"
  local cadir=/usr/local/share/ca-certificates

  # No CA directory means no proxy intercepting us — e.g. a local checkout.
  compgen -G "$cadir/*.crt" >/dev/null || return 0

  # Installing certutil is the only slow step, so that is what gets skipped on a
  # warm container. The import below always runs: it is about a second, and
  # ca-certificates' own postinst can land a partial set in the NSS db first, so
  # "some ccr-* nickname already exists" is not proof the whole set is there.
  if ! command -v certutil >/dev/null; then
    apt-get update -qq >/dev/null 2>&1 || return 0
    apt-get install -y --no-install-recommends libnss3-tools >/dev/null 2>&1 || return 0
    command -v certutil >/dev/null || return 0
  fi

  mkdir -p "$nssdb"
  [ -f "$nssdb/cert9.db" ] || certutil -d "sql:$nssdb" -N --empty-password >/dev/null 2>&1 || return 0

  local work cert nick
  work=$(mktemp -d) || return 0
  for cert in "$cadir"/*.crt; do
    # A .crt may hold a chain; split so each cert is imported under its own name.
    csplit -sz -f "$work/$(basename "$cert" .crt)-" -b '%02d.pem' \
      "$cert" '/BEGIN CERTIFICATE/' '{*}' 2>/dev/null || cp "$cert" "$work/$(basename "$cert" .crt)-00.pem"
  done
  for cert in "$work"/*.pem; do
    [ -f "$cert" ] || continue
    nick="ccr-$(basename "$cert" .pem)"
    # A nickname collision makes -A fail outright (SEC_ERROR_ADDING_CERT) rather
    # than replace, so when the proxy rotates its CA into the same filename the
    # stale certificate would survive and the browser would start failing again
    # with ERR_CERT_AUTHORITY_INVALID. Drop any existing entry first.
    certutil -d "sql:$nssdb" -D -n "$nick" >/dev/null 2>&1 || true
    # -t C,, = trusted CA for TLS server auth only; not email, not code signing.
    certutil -d "sql:$nssdb" -A -t "C,," -n "$nick" -i "$cert" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}

# stdout is the hook protocol channel — keep any stray output off it.
trust_proxy_cas_in_nssdb >&2 || true
exit 0
