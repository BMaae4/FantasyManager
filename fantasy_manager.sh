#!/usr/bin/env bash
# fantasy_manager.sh - Sleeper weekly decision support (lineup / waivers / trades)
#
# Launcher for macOS and Linux. The application itself is lib/fm_app.py
# (command line, configuration, fetching, caching, analysis and reports);
# the Windows app (FantasyManager.ps1) runs the same module. Only Python 3.8+
# is needed: no jq, curl or particular bash version.
#
# Read-only: this tool NEVER submits lineups, waiver claims or trades.
# Run ./fantasy_manager.sh --help for options. Exit codes: 0 ok, 2 usage,
# 3 missing dependency, 4 data error.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$SCRIPT_DIR/lib/fm_app.py"

find_python() {
    local candidate
    for candidate in "${FM_PYTHON:-}" python3 python; do
        [ -n "$candidate" ] || continue
        command -v "$candidate" >/dev/null 2>&1 || continue
        if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

if ! PYTHON="$(find_python)"; then
    printf '%s [ERROR] Python 3.8 or newer is required (install python3, or set FM_PYTHON).\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
    exit 3
fi
if [ ! -f "$APP" ]; then
    printf '%s [ERROR] Missing %s; reinstall the tool.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP" >&2
    exit 3
fi

exec "$PYTHON" "$APP" "$@"
