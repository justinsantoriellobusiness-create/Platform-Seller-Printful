#!/usr/bin/env bash
# Makes npx-launched MCP servers start reliably.
#
# npm on this image extracts *some* packages' bin entries as mode 644 while
# every other cached package gets 755. npx runs a package through its generated
# `node_modules/.bin/<name>` shim, which has to be executable — so a 644 bin
# dies with "Permission denied" before the MCP handshake, and the client
# reports it as "Connection closed" / CONNECT_TIMEOUT. That symptom points at
# the network and it is not the network.
#
# .claude/mcp/chrome-mcp.sh sidesteps this for chrome-devtools-mcp by running
# the entry file with `node`, which never consults the executable bit. Every
# other npx-launched server in .mcp.json still goes through a shim, and npx can
# re-extract a package at any point — that is the "it works sometimes" part —
# so repair the cache as a whole at session start rather than one package once.
#
# Never fail session start over this: every step degrades to a no-op.
set -uo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

repair_npx_bin_permissions() {
  local shim target repaired=0
  for shim in "$HOME"/.npm/_npx/*/node_modules/.bin/*; do
    [ -e "$shim" ] || continue
    # The shim is normally a symlink into the package; readlink -f returns a
    # regular file unchanged, so this covers both layouts.
    target=$(readlink -f "$shim" 2>/dev/null) || continue
    [ -f "$target" ] && [ ! -x "$target" ] || continue
    # A bin we cannot chmod is not worth failing session start over.
    chmod +x "$target" 2>/dev/null && repaired=$((repaired + 1)) || true
  done
  if [ "$repaired" -gt 0 ]; then
    echo "repair-npx-bins: made $repaired npx bin(s) executable"
  fi
  return 0
}

# stdout is the hook protocol channel — keep any stray output off it.
repair_npx_bin_permissions >&2 || true
exit 0
