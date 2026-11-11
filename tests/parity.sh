#!/usr/bin/env bash
# Compares the PowerShell front end (FantasyManager.ps1 -NoGui) with
# fantasy_manager.sh on every fixture: same exit code and, on success, the
# same report apart from timestamps. Needs pwsh; skipped (exit 0) without it.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
PWSH="${PWSH:-pwsh}"
if ! command -v "$PWSH" >/dev/null 2>&1; then
    echo "parity: $PWSH not found, skipped"
    exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fm_parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
NORMALISE='del(.metadata.generated_at, .metadata.projections.fetched_at) | .diagnostics.fetches |= map(del(.at))'
pass=0; fail=0; failed=()
for dir in "$ROOT"/tests/fixtures/*/; do
    name="$(basename "$dir")"
    for args in "" "--horizon 0" "--locked Wes Charlie" "--trade" "--value-trade"; do
        label="$name${args:+ ($args)}"
        # shellcheck disable=SC2086
        case "$args" in
            "") sh_args=(); ps_args=() ;;
            "--horizon 0") sh_args=(--horizon 0); ps_args=(-Horizon 0) ;;
            "--trade") [ "$name" = "ppr_basic" ] || continue
                sh_args=(--trade "Wes Delta, Ryan Echo for Team2 RB1; Bravo for Team2 TE1")
                ps_args=(-Trade "Wes Delta, Ryan Echo for Team2 RB1; Bravo for Team2 TE1") ;;
            "--value-trade") [ "$name" = "ppr_basic" ] || continue
                sh_args=(--value-trade "Team2 RB1 for Team3 RB2, Team4 WR3; Alpha for Team2 TE1" --scoring half --teams 4
                         --trade "Team2 RB1 for Team3 RB2")
                ps_args=(-ValueTrade "Team2 RB1 for Team3 RB2, Team4 WR3; Alpha for Team2 TE1" -Scoring half -Teams 4
                         -Trade "Team2 RB1 for Team3 RB2") ;;
            *) sh_args=(--locked "Wes Charlie"); ps_args=(-Locked "Wes Charlie") ;;
        esac
        FM_OFFLINE=1 FM_FIXTURES="$dir" "$ROOT/fantasy_manager.sh" --no-cache -q -f json "${sh_args[@]}" \
            > "$WORK/sh.json" 2>/dev/null
        sh_status=$?
        "$PWSH" -NoLogo -NoProfile -File "$ROOT/FantasyManager.ps1" -NoGui -Offline -Fixtures "$dir" -NoCache -Quiet "${ps_args[@]}" \
            > "$WORK/ps.json" 2>"$WORK/ps.err"
        ps_status=$?
        if [ "$sh_status" != "$ps_status" ]; then
            fail=$((fail + 1)); failed+=("$label: exit $sh_status vs $ps_status $(head -c 300 "$WORK/ps.err")")
            continue
        fi
        if [ "$sh_status" = "0" ]; then
            if ! diff <(jq -S "$NORMALISE" "$WORK/sh.json") <(jq -S "$NORMALISE" "$WORK/ps.json") > "$WORK/diff"; then
                fail=$((fail + 1)); failed+=("$label: report differs: $(head -c 600 "$WORK/diff")")
                continue
            fi
        fi
        pass=$((pass + 1))
    done
done
echo "parity: passed $pass  failed $fail"
for f in "${failed[@]}"; do printf '  - %s\n' "$f"; done
[ "$fail" -eq 0 ]
