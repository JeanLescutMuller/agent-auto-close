#!/usr/bin/env bash
# uninstall.sh - agent-auto-close: remove the PATH link and the deployed copy.
# Keeps ~/opt/agent-auto-close/data and logs (screen files, close log): delete them by hand if wanted.
# Usage: bash uninstall.sh
set -euo pipefail

OPT="$HOME/opt/agent-auto-close"
LINK="$HOME/.local/bin/agent-auto-close"

# Remove the link only if it points into our deployed copy.
if [[ -L "$LINK" && "$(readlink "$LINK")" == "$OPT/"* ]]; then
    rm -f "$LINK"
fi
if [[ -f "$OPT/bin/agent-auto-close" ]]; then
    rm -f "$OPT/bin/agent-auto-close"
fi
rmdir "$OPT/bin" 2>/dev/null || true
if [[ -f "$OPT/uninstall.sh" ]]; then
    rm -f "$OPT/uninstall.sh"
fi
echo "Uninstalled agent-auto-close (kept: $OPT/data, $OPT/logs)."
