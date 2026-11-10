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
    '[.trades.partners[].packages[] | select(.fairness_gap > ([1.0 * .window_weeks, 0.10 * ([.value_given, .value_received] | max)] | max) + 0.01)] | length == 0'
assert_json "trade shows depth context" \
    '[.trades.partners[] | select(.depth_before == null)] | length == 0'
assert_json "my needs identified" '.trades.my_needs != null'

run_case ppr_basic --format json --skip-waivers --skip-trades
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
    '[keys[]] == ["custom_trades","diagnostics","lineup","matchup","metadata","rosters","schema_version","trades","waivers","warnings"]'

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
section "regressions"
# --------------------------------------------------------------------------
# The script must be runnable as ./fantasy_manager.sh from a fresh clone.
if [ -x "$SCRIPT" ]; then pass "script is executable"; else fail "script is executable"; fi
if git -C "$ROOT" rev-parse >/dev/null 2>&1; then
    if git -C "$ROOT" ls-files -s fantasy_manager.sh | grep -q '^100755'; then
        pass "git records the executable bit"
    else
        fail "git records the executable bit" "run: git update-index --chmod=+x fantasy_manager.sh"
    fi
fi

# --quiet must still print errors.
run_case ppr_basic --league-id abc --quiet
assert_status "--quiet bad league id exits 2" 2
assert_match "--quiet still shows errors" "$STDERR" '\[ERROR\].*League id'

# Offline fixture runs must not touch the default (real) cache directory.
FAKE_XDG="$WORK/xdg_cache"
mkdir -p "$FAKE_XDG"
STDOUT="$(XDG_CACHE_HOME="$FAKE_XDG" FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/ppr_basic" \
    "$SCRIPT" --format json 2>"$WORK/stderr")"
STATUS=$?
assert_status "offline run without --cache-dir exits 0" 0
if [ -z "$(find "$FAKE_XDG" -type f 2>/dev/null)" ]; then
    pass "offline run leaves the default cache untouched"
else
    fail "offline run leaves the default cache untouched" "$(find "$FAKE_XDG" -type f)"
fi

# A bench player on bye (no projection) must not be suggested as a drop.
run_case bye_week_bench --format json
assert_status "bye week case exits 0" 0
assert_json "bye-week bench player never suggested as drop" \
    '[.waivers.groups[][] | .drop_candidate.player_id] | index("rb2") == null'
run_case bye_week_bench --format json --horizon 0
assert_json "protected bye-week player is disclosed (this week only)" \
    '[.warnings[] | select(test("Not suggested as drops"))] | length == 1'

# Rolling waivers with a populated waiver_budget are not FAAB.
run_case rolling_waivers --format json
assert_json "rolling waivers detected as waiver priority" '.waivers.waiver.type == "waiver priority"'
assert_json "no FAAB bids for rolling waivers" \
    '[.waivers.groups[][] | .suggested_bid | select(. != null)] | length == 0'
assert_json "no budget shown for rolling waivers" '.waivers.waiver.budget == null'

# Sleeper reports suspensions as injury_status "Sus".
run_case suspended_player --format json
assert_json "suspended (Sus) player not recommended" \
    '[.lineup.slots[].recommended.player_id] | index("rb3") == null'
assert_json "suspended player listed as excluded risk" \
    '[.lineup.risk[] | select(.player_id == "rb3" and .excluded_from_recommendations)] | length == 1'

# HTTP 404 is not retried (only 408/429/5xx/connection errors are).
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
echo call >> "$FAKE_CURL_LOG"
out=""
while [ $# -gt 0 ]; do
    case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ] && printf 'not found' > "$out"
printf '%s' "${FAKE_CURL_STATUS:-404}"
FAKE
chmod +x "$FAKE_BIN/curl"
FAKE_CURL_LOG="$WORK/curl_calls"
: > "$FAKE_CURL_LOG"
STDOUT="$(PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_CURL_STATUS=404 \
    "$SCRIPT" --no-cache --format json 2>"$WORK/stderr")"
STATUS=$?
assert_status "404 on /state/nfl fails with data error" 4
CALLS="$(wc -l < "$FAKE_CURL_LOG" | tr -d ' ')"
if [ "$CALLS" = "1" ]; then pass "404 is not retried"; else fail "404 is not retried" "curl called $CALLS times"; fi

# --------------------------------------------------------------------------
section "locks, week rollover and live matchup"
# --------------------------------------------------------------------------
run_case locked_players --format json
assert_status "locked case exits 0" 0
assert_json "starter with live points is LOCKED in place" \
    '.lineup.slots[0] | .action == "LOCKED" and .recommended.player_id == "qb1"'
assert_json "bench players whose game is final are never started" \
    '[.lineup.slots[].recommended.player_id] | (index("rb3") == null and index("wr3") == null)'
assert_json "open slot still optimised around locks" \
    '[.lineup.slots[] | select(.slot == "FLEX")][0].recommended.player_id == "rb5"'
assert_json "locked bench players reported" \
    '[.lineup.locks.locked_bench[].player_id] == ["rb3","rb4","wr3","wr4"]'
assert_json "locked slots are not listed as actions" \
    '[.lineup.actions[] | select(.action == "LOCKED")] | length == 0'
assert_json "projected final mixes live and projected points" '.matchup.my_projected_final == 99.4'
assert_json "lock source uses the schedule" '.lineup.locks.source == "game schedule + live points"'
assert_json "free agent whose game is over is judged on next week" \
    '[.waivers.groups.priority[] | select(.player_id == "fa_wr1" and .evaluated_week == 6 and .net_gain > 0)] | length == 1'
assert_json "next-week judgement is disclosed" \
    '[.waivers.groups[][] | select(.player_id == "fa_wr1") | .notes[] | select(test("judged on week 6"))] | length == 1'
assert_json "players who already played are left out of the risk list" \
    '[.lineup.risk[] | select(.player_id == "rb3")] | length == 0'
run_case locked_players --format json --horizon 0
assert_json "without a window, a kicked-off free agent stays this-week" \
    '[.waivers.groups[][] | select(.player_id == "fa_wr1") | .evaluated_week] | all(. == 5)'
run_case locked_players --format text
assert_match "text report lists locked players" "$STDOUT" 'Locked \(game started, cannot move\): Quinn Alpha'
run_case locked_players --format markdown
assert_match "markdown lists locked players" "$STDOUT" 'Locked \(game started\)'

run_case ppr_basic --format json
assert_json "pre-game week has no locks" \
    '(.lineup.locks.locked_starters | length) == 0 and (.lineup.locks.locked_bench | length) == 0'

run_case week_complete --format json
assert_json "finished week rolls over to the next" '.metadata.week == 6 and .metadata.week_rolled_from == 5'
run_case week_complete --format json --week 5
assert_json "explicit --week is never rolled over" '.metadata.week == 5 and .metadata.week_rolled_from == null'
run_case week_complete --format text
assert_match "rollover explained in text report" "$STDOUT" 'every week 5 game is final'

run_case no_schedule --format json
assert_status "missing schedule is not fatal" 0
assert_json "missing schedule warns" '[.warnings[] | select(test("schedule unavailable"))] | length == 1'
assert_json "live points still lock players without a schedule" \
    '[.lineup.slots[] | select(.action == "LOCKED") | .current.player_id] == ["rb2"]'
assert_json "zero live points do not lock" '.lineup.slots[0].action != "LOCKED"'

run_case ppr_basic --format json --locked "Wes Charlie, nobody here"
assert_json "--locked by name keeps a player out" '[.lineup.slots[].recommended.player_id] | index("wr3") == null'
assert_json "unmatched --locked entries are reported" '[.warnings[] | select(test("nobody here"))] | length == 1'

# --------------------------------------------------------------------------
section "position scoring fallback and trade attribution"
# --------------------------------------------------------------------------
run_case kdef_fallback --format json
assert_json "DEF and K switch to the provider total" '.metadata.scoring.position_fallback == {"DEF":"pts_ppr","K":"pts_ppr"}'
assert_json "fallback explained in the warning" '[.warnings[] | select(test("DEF and K use"))] | length == 1'
run_case ppr_basic --format json
assert_json "no fallback when DEF/K categories are covered" '.metadata.scoring.position_fallback == {}'

run_case two_way_player --format json
assert_json "two-way player not counted as a DB need" \
    '(.trades.league_average_depth | has("DB") | not) and ([.trades.my_needs[].position] | index("DB") == null)'
run_case ppr_basic --format json
assert_json "trade frameworks need a real gain for both sides" \
    '[.trades.partners[].packages[] | select(.my_gain < 0.5 or .their_gain < 0.5)] | length == 0'

# --------------------------------------------------------------------------
section "multi-week window"
# --------------------------------------------------------------------------
run_case ppr_basic --format json
assert_json "window covers this week and the next three" '.metadata.window_weeks == [5,6,7,8]'
assert_json "rest-of-season value is scored" '.waivers.weights_used | has("rest_of_season_value")'
assert_json "waiver rows carry a window gain" '[.waivers.groups.priority[] | select(.window_gain == null)] | length == 0'
assert_json "trade packages report this-week gains too" \
    '[.trades.partners[].packages[] | select(.my_gain_this_week == null or .window_weeks != 4)] | length == 0'
run_case ppr_basic --format json --horizon 0
assert_json "--horizon 0 values this week only" '.metadata.window_weeks == [5]'
assert_json "--horizon 0 omits rest-of-season value" '.waivers.omitted_components | index("rest_of_season_value") != null'
run_case ppr_basic --horizon 7
assert_status "--horizon above 6 rejected" 2

run_case stash_candidate --format json
assert_json "player on bye this week appears as a stash" \
    '[.waivers.groups.bench_upgrades[] | select(.player_id == "fa_stash" and .window_gain > 0 and .projection == null)] | length == 1'
run_case stash_candidate --format json --horizon 0
assert_json "stash invisible when only this week counts" '[.waivers.groups[][] | select(.player_id == "fa_stash")] | length == 0'

run_case bye_qb_partner --format json --horizon 0
assert_json "this-week-only logic sells a QB to a team on bye" \
    '[.trades.partners[] | select(.roster_id == 3) | .packages[] | select([.give[].position] | index("QB"))] | length > 0'
run_case bye_qb_partner --format json
assert_json "window logic does not exploit a one-week bye" \
    '[.trades.partners[] | select(.roster_id == 3) | .packages[] | select([.give[].position] | index("QB"))] | length == 0'

run_case week_complete --format json
assert_json "window follows the rolled-over week" '.metadata.window_weeks == [6,7,8]'
assert_json "missing future week is disclosed" '[.warnings[] | select(test("week\\(s\\) 9 unavailable"))] | length == 1'

# --------------------------------------------------------------------------
section "trade analyzer"
# --------------------------------------------------------------------------
run_case ppr_basic --format json --skip-waivers --skip-trades
assert_json "no trade analyzer section unless asked" '.custom_trades == null'
assert_json "report lists every roster for building trades" \
    '(.rosters | length) == 4 and ([.rosters[] | select(.is_me)] | length) == 1 and ([.rosters[].players[] | select(.window_projection == null)] | length) == 0'

run_case ppr_basic --format json --skip-waivers --skip-trades \
    --trade "Wes Delta, Ryan Echo for Team2 RB1; Quinn Alpha for Team2 QB1; Wes Delta for Team2 WR2, Team2 WR3"
assert_status "trade analyzer run exits 0" 0
assert_json "lopsided win grades A+ for me, F for them" \
    '.custom_trades[0] | .my_grade == "A+" and .their_grade == "F" and .acceptance == "unlikely" and .partner.roster_id == 2'
assert_json "small loss grades C- and favours them" \
    '.custom_trades[1] | .my_grade == "C-" and .their_grade == "B-" and .acceptance == "likely" and (.verdict | test("not recommended"))'
assert_json "gains cover the whole window" \
    '.custom_trades[0] | (.my_weekly_gains | length) == 4 and .my_gain == 16 and .my_gain_per_week == 4'
assert_json "2-for-1 notes the open roster spot" \
    '[.custom_trades[0].notes[] | select(test("Opens 1 roster spot"))] | length == 1'
assert_json "receiving more players drops my cheapest player" \
    '.custom_trades[2] | [.my_drops[].player_id] == ["qb2"] and .get[1].weeks_started_after == 0'
assert_json "unused incoming player is called out" \
    '[.custom_trades[2].notes[] | select(test("would not start for you"))] | length == 1'

run_case ppr_basic --format json --skip-waivers --skip-trades \
    --trade "Bravo for Team2 TE1; nobody for Team2 WR1; Wes Charlie for Team2 WR1, Team3 WR1; Team2 TE1; id:wr3 for id:t2_wr1; quinn alpha for TEAM2 qb1"
assert_json "ambiguous name explained" '.custom_trades[0].error | test("ambiguous: Quinn Bravo, Ryan Bravo, Tom Bravo, Wes Bravo")'
assert_json "unknown name explained" '.custom_trades[1].error | test("not found on your roster")'
assert_json "three-team trade rejected" '.custom_trades[2].error | test("only two-team trades")'
assert_json "one-sided input explained" '.custom_trades[3].error | test("players you give for players you get")'
assert_json "Sleeper ids accepted" '.custom_trades[4] | .error == null and .give[0].player_id == "wr3" and .get[0].player_id == "t2_wr1"'
assert_json "names match case-insensitively" '.custom_trades[5] | .error == null and .give[0].player_id == "qb1"'

run_case ppr_basic --format json --skip-waivers --skip-trades --horizon 0 --trade "Quinn Alpha for Team2 QB1"
assert_json "--horizon 0 grades this week only" \
    '.custom_trades[0] | (.window_weeks == [5]) and ([.notes[] | select(test("this week only"))] | length == 1)'

run_case ppr_basic --skip-waivers --skip-trades --trade "Wes Delta, Ryan Echo for Team2 RB1"
assert_match "text report shows the grades" "$STDOUT" 'GRADE  you A\+  them F'
run_case ppr_basic --format markdown --skip-waivers --skip-trades --trade "Wes Delta, Ryan Echo for Team2 RB1"
assert_match "markdown shows the grade" "$STDOUT" '\*\*Your grade: A\+\*\*'

# --------------------------------------------------------------------------
printf '\n%s\n' "------------------------------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'failed tests:\n'
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
exit 0
