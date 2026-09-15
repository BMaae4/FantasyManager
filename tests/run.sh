#!/usr/bin/env bash
# Offline test suite for fantasy_manager.sh.
# No network access is performed: every case runs against the sanitized
# fixtures in tests/fixtures with --offline.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
SCRIPT="$ROOT/fantasy_manager.sh"
FIXTURES="$HERE/fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fm_tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
FAILED_NAMES=()

STDOUT=""
STDERR=""
STATUS=0

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1")
    printf 'FAIL %s\n' "$1"
    [ -n "${2:-}" ] && printf '       %s\n' "$2"
    if [ -n "${FM_TEST_VERBOSE:-}" ]; then
        printf '       --- stdout ---\n'; head -40 <<< "$STDOUT"
        printf '       --- stderr ---\n'; head -40 <<< "$STDERR"
    fi
    return 0
}

run_case() {
    # run_case <fixture-or-empty> [args...]
    local fixture="$1"; shift
    local cache="$WORK/cache.$$.$RANDOM"
    rm -rf "$cache"
    if [ -n "$fixture" ]; then
        STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/$fixture" \
            "$SCRIPT" --cache-dir "$cache" "$@" 2>"$WORK/stderr")"
    else
        STDOUT="$("$SCRIPT" --cache-dir "$cache" "$@" 2>"$WORK/stderr")"
    fi
    STATUS=$?
    STDERR="$(cat "$WORK/stderr")"
    return 0
}

run_case_cache() {
    # run_case_cache <fixture> <cache-dir> [args...]
    local fixture="$1" cache="$2"; shift 2
    STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/$fixture" \
        "$SCRIPT" --cache-dir "$cache" "$@" 2>"$WORK/stderr")"
    STATUS=$?
    STDERR="$(cat "$WORK/stderr")"
    return 0
}

assert_status() {
    # assert_status <name> <expected>
    if [ "$STATUS" -eq "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $STATUS"; fi
}

assert_json() {
    # assert_json <name> <jq filter expected to be true>
    if jq -e "$2" >/dev/null 2>&1 <<< "$STDOUT"; then
        pass "$1"
    else
        fail "$1" "jq filter false: $2"
    fi
}

assert_match() {
    # assert_match <name> <text> <extended regex>
    if grep -Eq -- "$3" <<< "$2"; then pass "$1"; else fail "$1" "no match for: $3"; fi
}

assert_no_match() {
    if grep -Eq -- "$3" <<< "$2"; then fail "$1" "unexpected match: $3"; else pass "$1"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# --------------------------------------------------------------------------
section "static checks"
# --------------------------------------------------------------------------
if bash -n "$SCRIPT"; then pass "bash -n fantasy_manager.sh"; else fail "bash -n fantasy_manager.sh"; fi
if python3 -m py_compile "$ROOT/lib/fm_analysis.py"; then
    pass "python3 -m py_compile lib/fm_analysis.py"
else
    fail "python3 -m py_compile lib/fm_analysis.py"
fi
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x "$SCRIPT" "$HERE/run.sh"; then pass "shellcheck"; else fail "shellcheck"; fi
else
    printf 'skip shellcheck (not installed)\n'
fi
MOJIBAKE_RE="$(printf '&(amp|lt|gt|quot|#[0-9]+);|\xc3\xa2\xe2\x82\xac|\xc3\x83\xc2|\xc3\x82\xc2')"
for f in "$SCRIPT" "$ROOT/lib/fm_analysis.py" "$HERE/run.sh" "$HERE/make_fixtures.py"; do
    name="encoding $(basename "$f")"
    if LC_ALL=C grep -q $'\r' "$f"; then
        fail "$name" "CRLF line endings found"
    elif LC_ALL=C grep -Eq "$MOJIBAKE_RE" "$f"; then
        fail "$name" "HTML entity or mojibake found"
    elif ! iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1; then
        fail "$name" "not valid UTF-8"
    else
        pass "$name"
    fi
done

# --------------------------------------------------------------------------
section "defaults and CLI validation"
# --------------------------------------------------------------------------
assert_match "default league id preserved" "$(grep -m1 DEFAULT_LEAGUE_ID= "$SCRIPT")" '1400680781302525952'
assert_match "default username preserved" "$(grep -m1 DEFAULT_USERNAME= "$SCRIPT")" 'MaTrasaMaae'
assert_match "api base is plain text" "$(grep -m1 DEFAULT_API= "$SCRIPT")" 'https://api\.sleeper\.app/v1'

run_case "" --help
assert_status "--help exits 0" 0
assert_match "--help mentions defaults" "$STDOUT" '1400680781302525952'

run_case "" --version
assert_status "--version exits 0" 0

run_case "" --week
assert_status "missing option value rejected" 2
assert_match "missing value message" "$STDERR" "requires a value"

run_case "" --league-id abc --offline --fixtures "$FIXTURES/ppr_basic"
assert_status "non-numeric league id rejected" 2

run_case "" --username '' --offline --fixtures "$FIXTURES/ppr_basic"
assert_status "empty username rejected" 2

run_case "" --week 0 --offline --fixtures "$FIXTURES/ppr_basic"
assert_status "week 0 rejected" 2
run_case "" --week 19 --offline --fixtures "$FIXTURES/ppr_basic"
assert_status "week 19 rejected" 2
run_case "" --top 0 --offline --fixtures "$FIXTURES/ppr_basic"
assert_status "top 0 rejected" 2
run_case "" --top 51 --offline --fixtures "$FIXTURES/ppr_basic"
assert_status "top 51 rejected" 2
run_case "" --format xml --offline --fixtures "$FIXTURES/ppr_basic"
assert_status "unknown format rejected" 2
run_case "" --bogus
assert_status "unknown option rejected" 2
run_case "" extra-arg
assert_status "positional argument rejected" 2
run_case "" --offline
assert_status "--offline without fixtures rejected" 2
run_case "" --offline --fixtures "$WORK/does-not-exist"
assert_status "missing fixture directory rejected" 2

run_case ppr_basic --format json --top 3 --top 5
assert_status "last duplicate option wins (exit)" 0
assert_json "last duplicate option wins (value)" '.metadata.top_n == 5'
run_case ppr_basic --format json
assert_json "metadata echoes read-only mode" '.metadata.read_only == true'

# --------------------------------------------------------------------------
section "configuration precedence"
# --------------------------------------------------------------------------
cat > "$WORK/config" <<'EOF'
# comment line
top_n=7
format=json
churn_threshold=0.25
EOF
STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/ppr_basic" \
    "$SCRIPT" --cache-dir "$WORK/c1" --config "$WORK/config" 2>"$WORK/stderr")"
STATUS=$?
STDERR="$(cat "$WORK/stderr")"
assert_status "config file honoured (exit)" 0
assert_json "config file sets top_n" '.metadata.top_n == 7'

STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/ppr_basic" FM_TOP_N=9 \
    "$SCRIPT" --cache-dir "$WORK/c2" --config "$WORK/config" 2>"$WORK/stderr")"
STATUS=$?
assert_json "environment overrides config" '.metadata.top_n == 9'

STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/ppr_basic" FM_TOP_N=9 \
    "$SCRIPT" --cache-dir "$WORK/c3" --config "$WORK/config" --top 4 2>"$WORK/stderr")"
STATUS=$?
assert_json "cli overrides environment" '.metadata.top_n == 4'

# --------------------------------------------------------------------------
section "lineup optimisation"
# --------------------------------------------------------------------------
run_case ppr_basic --format json
assert_status "ppr_basic exits 0" 0
assert_json "ppr_basic optimal >= current" '.lineup.optimal_points >= .lineup.current_points'
assert_json "ppr_basic uses league scoring" '.metadata.scoring.mode | test("scoring_settings")'
assert_json "ppr_basic slot count matches league" \
    '(.lineup.slots | length) == 9'
assert_json "ppr_basic reports actions" \
    '[.lineup.slots[] | select(.action != "KEEP")] | length > 0'
assert_json "ppr_basic gain equals difference" \
    '((.lineup.optimal_points - .lineup.current_points) * 100 | round) == (.lineup.gain * 100 | round)'
assert_json "ppr_basic is read-only" '.diagnostics.read_only == true'
assert_json "provenance records projection url" \
    '.metadata.projections.url | test("projections/nfl/2025/5")'
assert_json "provenance records fetch time and source" \
    '.metadata.projections.fetched_at != null and .metadata.projections.source != null'

FIRST="$STDOUT"
run_case ppr_basic --format json
DET_A="$(jq -S 'del(.metadata.generated_at, .metadata.projections, .diagnostics)' <<< "$FIRST")"
DET_B="$(jq -S 'del(.metadata.generated_at, .metadata.projections, .diagnostics)' <<< "$STDOUT")"
if [ "$DET_A" = "$DET_B" ]; then pass "deterministic output"; else fail "deterministic output"; fi

run_case custom_scoring --format json
assert_status "custom_scoring exits 0" 0
assert_json "custom_scoring warns about unsupported keys" \
    '[.warnings[] | select(test("no matching projection stat"))] | length > 0'
assert_json "custom_scoring lists unsupported categories" \
    '(.metadata.scoring.unsupported_keys | index("idp_tkl_solo")) != null'

run_case superflex --format json
assert_status "superflex exits 0" 0
assert_json "superflex slot present" \
    '[.lineup.slots[] | select(.slot == "SUPER_FLEX")] | length == 1'
assert_json "superflex picks a quarterback" \
    '[.lineup.slots[] | select(.slot == "SUPER_FLEX") | .recommended.position] == ["QB"]'

run_case overlapping_flex --format json
assert_status "overlapping_flex exits 0" 0
assert_json "overlapping flex slots all filled" \
    '[.lineup.slots[] | select(.recommended == null)] | length == 0'
assert_json "no player used twice" \
    '([.lineup.slots[] | .recommended.player_id] | length) == ([.lineup.slots[] | .recommended.player_id] | unique | length)'

run_case empty_starters --format json
assert_status "empty_starters exits 0" 0
assert_json "empty slot reported" \
    '[.lineup.slots[] | select(.action == "EMPTY SLOT" or .current == null)] | length > 0'

run_case null_fields --format json
assert_status "null_fields exits 0" 0

run_case missing_player --format json
assert_status "missing_player exits 0" 0
assert_json "missing player noted" \
    '[.warnings[] | select(test("player database"; "i"))] | length > 0'

run_case no_eligible_slot --format json
assert_status "no_eligible_slot exits 0" 0
assert_json "unfillable slot flagged" \
    '[.lineup.slots[] | select(.slot == "K" and .recommended == null)] | length == 1'
assert_json "unfillable slot warned" \
    '[.warnings[] | select(test("no eligible"; "i"))] | length > 0'

run_case missing_projection --format json
assert_status "missing_projection exits 0" 0
assert_json "player without projection is flagged" \
    '[.warnings[] | select(test("no projection"; "i"))] | length > 0'

run_case already_optimal --format json
assert_status "already_optimal exits 0" 0
assert_json "already optimal has no gain" '.lineup.gain == 0'
assert_json "already optimal keeps everyone" \
    '[.lineup.slots[] | select(.action != "KEEP")] | length == 0'

run_case unequal_changes --format json
assert_status "unequal_changes exits 0" 0
assert_json "unequal changes fill empty slots" \
    '[.lineup.slots[] | select(.current == null and .recommended != null)] | length == 2'

run_case dynasty_taxi --format json
assert_status "dynasty_taxi exits 0" 0
assert_json "taxi player is not started" \
    '[.lineup.slots[] | select(.recommended.player_id == "wr3")] | length == 0'
assert_json "reserve player is not started" \
    '[.lineup.slots[] | select(.recommended.player_id == "rb3")] | length == 0'

run_case ppr_basic --format json --threshold 100
assert_json "high churn threshold suppresses moves" \
    '[.lineup.slots[] | select(.action != "KEEP" and .below_threshold != true)] | length == 0'
assert_json "suppressed moves are retained as optional" \
    '(.lineup.optional_actions | length) > 0'

# --------------------------------------------------------------------------
section "risk, matchup, waivers and trades"
# --------------------------------------------------------------------------
run_case ppr_basic --format json
assert_json "risky players are not recommended" \
    '[.lineup.slots[] | select(.recommended.player_id == "fa_hurt1" or .recommended.player_id == "fa_ret1")] | length == 0'
assert_json "matchup present" '.matchup != null and .matchup.opponent_team != null'
assert_json "matchup differential computed" '.matchup.differential != null'
assert_json "matchup caveat stated" '.matchup.note | test("correlation")'
# shellcheck disable=SC2016  # jq filter, not a shell expansion
assert_json "waivers ranked by net gain" \
    '[.waivers.groups.priority[].net_gain] as $g | $g == ($g | sort | reverse)'
assert_json "waiver entries carry replacement context" \
    '[.waivers.groups.priority[] | select(.drop_candidate == null)] | length == 0'
assert_json "faab bid suggested" \
    '[.waivers.groups.priority[] | select(.suggested_bid == null)] | length == 0'
assert_json "waiver omissions disclosed" \
    '(.waivers.omitted_components | length) > 0'
assert_json "waiver weights renormalised" \
    '([.waivers.weights_used[]] | add | . * 1000 | round) == 1000'
assert_json "unavailable players routed to avoid" \
    '[.waivers.groups.avoid[].player_id] | index("fa_inactive1") != null'
assert_json "trades produce a balanced package" \
    '[.trades.partners[].packages[]] | length > 0'
assert_json "trade packages help both teams" \
    '[.trades.partners[].packages[] | select(.my_gain <= 0 or .their_gain <= 0)] | length == 0'
assert_json "trade fairness within tolerance" \
    '[.trades.partners[].packages[] | select(.fairness_gap > 2)] | length == 0'
assert_json "trade shows depth context" \
    '[.trades.partners[] | select(.depth_before == null)] | length == 0'
assert_json "my needs identified" '.trades.my_needs != null'

run_case ppr_basic --format json --no-waivers --no-trades
assert_json "waivers skippable" '.waivers == null'
assert_json "trades skippable" '.trades == null'

# --------------------------------------------------------------------------
section "projection provider failures"
# --------------------------------------------------------------------------
for case_name in projections_html projections_malformed projections_empty projections_schema_change http_429; do
    run_case "$case_name" --format json
    assert_status "$case_name fails loudly" 4
    assert_match "$case_name explains projections" "$STDERR" 'projection|Projection'
    assert_no_match "$case_name does not report zeros" "$STDOUT" '"optimal_points"'
done

run_case http_500 --format json
assert_status "http_500 on league fails" 4
assert_match "http_500 mentions league" "$STDERR" '[Ll]eague'

# stale cache fallback: seed the cache, then run a fixture whose projection
# endpoint returns 503.
STALE_CACHE="$WORK/stale_cache_dir"
mkdir -p "$STALE_CACHE"
cp "$FIXTURES/stale_cache/projections_cache_seed.json" "$STALE_CACHE/projections_2025_regular_5.json"
touch -d '2 hours ago' "$STALE_CACHE/projections_2025_regular_5.json" 2>/dev/null \
    || touch -A -020000 "$STALE_CACHE/projections_2025_regular_5.json"
run_case_cache stale_cache "$STALE_CACHE" --format json --cache-ttl 60
assert_status "stale cache fallback exits 0" 0
assert_json "stale cache marked in provenance" \
    '.metadata.projections.source == "stale-cache" and .metadata.projections.stale == true'
assert_json "stale cache warning raised" \
    '[.warnings[] | select(test("STALE DATA"))] | length > 0'

run_case_cache stale_cache "$STALE_CACHE" --format text --cache-ttl 60
assert_match "stale warning visible in text report" "$STDOUT" 'STALE DATA'

# too old to use
touch -d '30 days ago' "$STALE_CACHE/projections_2025_regular_5.json" 2>/dev/null \
    || touch -A -720000 "$STALE_CACHE/projections_2025_regular_5.json"
run_case_cache stale_cache "$STALE_CACHE" --format json --cache-ttl 60
assert_status "expired stale cache refuses to run" 4

# --------------------------------------------------------------------------
section "caching behaviour"
# --------------------------------------------------------------------------
CACHE2="$WORK/cache_reuse"
run_case_cache ppr_basic "$CACHE2" --format json
assert_status "first cached run exits 0" 0
if [ -f "$CACHE2/projections_2025_regular_5.json" ] && [ -f "$CACHE2/players_nfl.json" ]; then
    pass "cache files written atomically"
else
    fail "cache files written atomically" "expected cache files in $CACHE2"
fi
if [ -n "$(find "$CACHE2" -name '*.tmp.*' -print -quit)" ]; then
    fail "no temporary cache files left behind"
else
    pass "no temporary cache files left behind"
fi
run_case_cache ppr_basic "$CACHE2" --format json
assert_json "second run uses cache" \
    '[.diagnostics.fetches[] | select(.key == "projections" and .source == "cache")] | length == 1'
run_case_cache ppr_basic "$CACHE2" --format json --no-cache
assert_json "--no-cache bypasses cache" \
    '[.diagnostics.fetches[] | select(.key == "projections" and .source == "cache")] | length == 0'

# --------------------------------------------------------------------------
section "output formats and logging"
# --------------------------------------------------------------------------
run_case ppr_basic --format text
assert_status "text report exits 0" 0
assert_match "text report has lineup section" "$STDOUT" '^LINEUP'
assert_match "text report has waivers section" "$STDOUT" '^WAIVERS'
assert_match "text report has trades section" "$STDOUT" '^TRADES'
assert_match "text report states read-only" "$STDOUT" 'read-only'

run_case ppr_basic --format markdown
assert_status "markdown report exits 0" 0
assert_match "markdown has headings" "$STDOUT" '^## Lineup'
assert_match "markdown has table" "$STDOUT" '^\| Slot \|'

run_case ppr_basic --format json
assert_json "json has metadata" '.metadata.league_id == "1400680781302525952"'
assert_json "json has diagnostics" '(.diagnostics.fetches | length) > 0'
assert_json "json keys stable" \
    '[keys[]] == ["diagnostics","lineup","matchup","metadata","schema_version","trades","waivers","warnings"]'

run_case ppr_basic --format json --quiet
assert_status "--quiet exits 0" 0
if [ -z "$STDERR" ]; then pass "--quiet silences diagnostics"; else fail "--quiet silences diagnostics" "stderr: $STDERR"; fi

run_case ppr_basic --format json --debug
assert_match "--debug emits debug lines" "$STDERR" '\[DEBUG\]'
assert_match "--debug logs effective configuration" "$STDERR" 'Effective configuration'
assert_json "diagnostics stay off stdout" 'type == "object"'

run_case ppr_basic --format json --output "$WORK/report.json"
assert_status "--output exits 0" 0
if jq -e '.lineup' "$WORK/report.json" >/dev/null 2>&1; then
    pass "--output writes the report to a file"
else
    fail "--output writes the report to a file"
fi

LOGFILE="$WORK/run.log"
run_case ppr_basic --format json --log-file "$LOGFILE" --verbose
if grep -q '\[INFO\]' "$LOGFILE" 2>/dev/null; then
    pass "--log-file captures structured logs"
else
    fail "--log-file captures structured logs"
fi

# --------------------------------------------------------------------------
printf '\n%s\n' "------------------------------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'failed tests:\n'
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
exit 0
