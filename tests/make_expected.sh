#!/usr/bin/env bash
# Writes the bash front end's report for every fixture to DIR as
# <case>.json plus <case>.status (exit code). The Windows CI job compares
# FantasyManager.ps1 against these.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
OUT="${1:?usage: make_expected.sh DIR}"
mkdir -p "$OUT"
for dir in "$ROOT"/tests/fixtures/*/; do
    name="$(basename "$dir")"
    FM_OFFLINE=1 FM_FIXTURES="$dir" "$ROOT/fantasy_manager.sh" --no-cache -q -f json > "$OUT/$name.json" 2>/dev/null
    echo $? > "$OUT/$name.status"
done
FM_OFFLINE=1 FM_FIXTURES="$ROOT/tests/fixtures/ppr_basic" "$ROOT/fantasy_manager.sh" --no-cache -q -f json --horizon 0 \
    > "$OUT/ppr_basic__horizon0.json" 2>/dev/null; echo $? > "$OUT/ppr_basic__horizon0.status"
FM_OFFLINE=1 FM_FIXTURES="$ROOT/tests/fixtures/ppr_basic" "$ROOT/fantasy_manager.sh" --no-cache -q -f json --locked "Wes Charlie" \
    > "$OUT/ppr_basic__locked.json" 2>/dev/null; echo $? > "$OUT/ppr_basic__locked.status"
echo "expected reports written to $OUT"
