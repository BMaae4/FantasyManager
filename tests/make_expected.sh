#!/usr/bin/env bash
# Writes the bash front end's report for every fixture to DIR as
# <case>.json plus <case>.status (exit code). The Windows CI job compares
# FantasyManager.ps1 against these.
set -uo pipefail
# No built-in league or user: supply the test league's.
export FM_LEAGUE_ID=100000000000000001 FM_USERNAME=TestManager
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
FM_OFFLINE=1 FM_FIXTURES="$ROOT/tests/fixtures/ppr_basic" "$ROOT/fantasy_manager.sh" --no-cache -q -f json \
    --trade "Wes Delta, Ryan Echo for Team2 RB1; Bravo for Team2 TE1" \
    > "$OUT/ppr_basic__trade.json" 2>/dev/null; echo $? > "$OUT/ppr_basic__trade.status"
FM_OFFLINE=1 FM_FIXTURES="$ROOT/tests/fixtures/ppr_basic" "$ROOT/fantasy_manager.sh" --no-cache -q -f json \
    --value-trade "Team2 RB1 for Team3 RB2, Team4 WR3; Alpha for Team2 TE1" --scoring half --teams 4 \
    > "$OUT/ppr_basic__value.json" 2>/dev/null; echo $? > "$OUT/ppr_basic__value.status"
FM_OFFLINE=1 FM_FIXTURES="$ROOT/tests/fixtures/espn_league" "$ROOT/fantasy_manager.sh" --no-cache -q -f json     --platform espn --league-id 555001 --team "Test Titans"     > "$OUT/espn_league__espn.json" 2>/dev/null; echo $? > "$OUT/espn_league__espn.status"
echo "expected reports written to $OUT"
