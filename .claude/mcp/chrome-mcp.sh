#!/usr/bin/env bash
# Launches chrome-devtools-mcp against a browser this machine actually has.
#
# Why this exists rather than `npx -y chrome-devtools-mcp@latest` in .mcp.json:
#
#  1. npx runs a package through the generated `.bin/<name>` shim, which has to
#     be executable. On this image npm extracts chrome-devtools-mcp's bins as
#     mode 644 — no +x — while every other cached package gets 755. The shim
#     then dies with "Permission denied" before the MCP handshake, and the
#     client reports it as CONNECT_TIMEOUT / "Connection closed", which reads
#     like a network problem and isn't one. Running the entry file with `node`
#     never consults the executable bit, so that whole class of failure is gone.
#  2. `@latest` re-resolves against the registry on every single session start.
#     A cold resolve can outrun the client's 30s connect timeout, which is the
#     other half of "sometimes it works". The version is pinned and cached.
#
# Order of preference for the entry file: a pinned local install, then any copy
# npx already downloaded (free, avoids a network round trip), then a one-time
# install. Nothing here needs the network on the common path.
set -uo pipefail

VERSION="${CHROME_MCP_VERSION:-1.9.0}"
HOME_DIR="${HOME:-/root}"
INSTALL_DIR="${CHROME_MCP_HOME:-$HOME_DIR/.claude/mcp/chrome-devtools-mcp-$VERSION}"
REL="node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"

find_entry() {
  [ -f "$INSTALL_DIR/$REL" ] && { printf '%s' "$INSTALL_DIR/$REL"; return 0; }
  local cached
  cached=$(ls -d "$HOME_DIR"/.npm/_npx/*/"$REL" /root/.npm/_npx/*/"$REL" 2>/dev/null | head -1)
  [ -n "$cached" ] && [ -f "$cached" ] && { printf '%s' "$cached"; return 0; }
  return 1
}

ENTRY=$(find_entry) || {
  mkdir -p "$INSTALL_DIR"
  # stdout is the MCP transport — every byte of install noise goes to stderr.
  npm install --prefix "$INSTALL_DIR" --no-audit --no-fund --loglevel=error \
    "chrome-devtools-mcp@$VERSION" >&2 || true
  ENTRY=$(find_entry)
}

if [ -z "${ENTRY:-}" ]; then
  echo "chrome-mcp: could not find or install chrome-devtools-mcp@$VERSION" >&2
  exit 1
fi

ARGS=()

# --browserUrl means "attach to a browser that is already running" (the
# chrome-my-browser server, pointed at a CDP endpoint). Everything below picks
# a binary to launch and shapes how it launches, none of which applies to a
# browser this script did not start — and --executablePath alongside
# --browserUrl is rejected outright. So when the caller passes it, hand the
# arguments straight through.
ATTACH=""
for arg in "$@"; do
  case "$arg" in --browserUrl|--browserUrl=*) ATTACH=1 ;; esac
done

if [ -n "$ATTACH" ]; then
  exec node "$ENTRY" "$@"
fi

# A browser binary the sandbox already ships beats one downloaded per session.
# The Playwright image path is first because that is what these containers have.
for c in "${CHROME_MCP_BROWSER:-}" \
         /opt/pw-browsers/chromium \
         /opt/pw-browsers/chromium-*/chrome-linux/chrome \
         /usr/bin/chromium /usr/bin/chromium-browser \
         /usr/bin/google-chrome /usr/bin/google-chrome-stable \
         "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
  if [ -n "$c" ] && [ -x "$c" ]; then ARGS+=("--executablePath=$c"); break; fi
done

# Cloud session: no display, no sandbox available, and outbound HTTPS only via
# the agent proxy. --isolated keeps each run's profile disposable.
if [ -n "${CLAUDE_CODE_REMOTE:-}" ]; then
  ARGS+=(--headless --isolated
         --chromeArg=--no-sandbox
         --chromeArg=--disable-setuid-sandbox
         --chromeArg=--disable-dev-shm-usage
         --chromeArg=--disable-gpu
         # Chrome phones home to clients2.google.com over plain HTTP on startup;
         # the proxy only serves CONNECT, so each one lands in its failure log
         # and buries anything real.
         --chromeArg=--disable-background-networking)

  if [ -n "${HTTPS_PROXY:-}" ]; then
    ARGS+=("--proxyServer=$HTTPS_PROXY")
    # The sandbox's egress proxy re-terminates TLS, and it cannot complete
    # Chromium's TLS 1.3 handshake: the tunnel opens, Chromium's ~1.8 KB
    # ClientHello goes out, 39 bytes come back, and the connection is reset —
    # every navigation failing as ERR_CONNECTION_RESET while curl through the
    # same proxy is fine. Measured, not guessed: capping at 1.2 is the only
    # thing that changed the result (disabling post-quantum key agreement, ECH
    # and QUIC each made no difference).
    #
    # This caps the protocol version. It does NOT weaken verification — the
    # certificate is still checked against the proxy CA in the NSS store, and
    # nothing here passes --ignore-certificate-errors. Scoped to the sandbox:
    # on a real machine there is no interception proxy and 1.3 is used.
    ARGS+=(--chromeArg=--ssl-version-max=tls1.2)
  fi
fi

exec node "$ENTRY" "${ARGS[@]}" "$@"
