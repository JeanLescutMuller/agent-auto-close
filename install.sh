#!/usr/bin/env bash
# install.sh - agent-auto-close: deploy the command to ~/opt/agent-auto-close and link it on the PATH.
#
#   ~/opt/agent-auto-close/bin/agent-auto-close   the deployed copy (from src/agent-auto-close)
#   ~/opt/agent-auto-close/{data,logs}/           screen files and the close log (kept by uninstall.sh)
#   ~/.local/bin/agent-auto-close                 symlink to the deployed copy
#
# No scheduler is installed: when `agent-auto-close idle` runs is not decided yet (README.md).
# Idempotent: safe to re-run at any time. Usage: bash install.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPT="$HOME/opt/agent-auto-close"
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/agent-auto-close"

command -v python3 >/dev/null || { echo "ERROR: python3 is required." >&2; exit 1; }

mkdir -p "$OPT/bin" "$OPT/data/close-screens" "$OPT/logs" "$BIN_DIR"
# Copy through a temp file + rename, so a running command never reads a half-written file.
cp "$SRC/src/agent-auto-close" "$OPT/bin/.agent-auto-close.new"
chmod 755 "$OPT/bin/.agent-auto-close.new"
mv -f "$OPT/bin/.agent-auto-close.new" "$OPT/bin/agent-auto-close"
cp "$SRC/uninstall.sh" "$OPT/uninstall.sh"

# A real file at the link path is not ours to replace: keep it and warn.
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    echo "WARNING: $LINK is a real file, not a link: left as is; remove it, then re-run." >&2
else
    ln -sfn "$OPT/bin/agent-auto-close" "$LINK"
fi

case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "NOTE: $BIN_DIR is not on your PATH." ;; esac
echo "Installed agent-auto-close $("$OPT/bin/agent-auto-close" --version | awk '{print $2}') in $OPT (link: $LINK)."
