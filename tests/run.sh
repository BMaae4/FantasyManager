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

# The tool has no built-in league or user; the suite supplies the test league's.
export FM_LEAGUE_ID=100000000000000001 FM_USERNAME=TestManager

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
for py in fm_app fm_analysis fm_espn; do
    if python3 -m py_compile "$ROOT/lib/$py.py"; then
        pass "python3 -m py_compile lib/$py.py"
    else
        fail "python3 -m py_compile lib/$py.py"
    fi
done
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
assert_match "no built-in league id" "$(grep -m1 "^DEFAULT_LEAGUE_ID = " "$ROOT/lib/fm_app.py")" '^DEFAULT_LEAGUE_ID = ""$'
assert_match "no built-in username" "$(grep -m1 "^DEFAULT_USERNAME = " "$ROOT/lib/fm_app.py")" '^DEFAULT_USERNAME = ""$'
STDOUT="$(env -u FM_LEAGUE_ID -u FM_USERNAME "$SCRIPT" --config "$WORK/none.env" --offline --fixtures "$FIXTURES/ppr_basic" 2>"$WORK/stderr")"
STATUS=$?; STDERR="$(cat "$WORK/stderr")"
assert_status "no league configured exits 2" 2
assert_match "no league configured is explained" "$STDERR" 'No league set'
STDOUT="$(env -u FM_LEAGUE_ID -u FM_USERNAME "$SCRIPT" --config "$WORK/none.env" --print-config 2>/dev/null)"
assert_match "--print-config works before a league is chosen" "$STDOUT" '"league_id": ""'
assert_match "api base is plain text" "$(grep -m1 "^DEFAULT_API = " "$ROOT/lib/fm_app.py")" 'https://api\.sleeper\.app/v1'

run_case "" --help
assert_status "--help exits 0" 0
assert_match "--help says the league is required" "$STDOUT" 'League id \(required'

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

# Hand-written config files: spaces around "=", quotes, Windows line endings.
printf '# saved from Notepad\r\nleague_id = 100000000000000001\r\n  top_n = 6 \r\nusername = "TestManager"\r\nformat=json\r\n' > "$WORK/config_crlf"
STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/ppr_basic" \
    "$SCRIPT" --cache-dir "$WORK/c4" --config "$WORK/config_crlf" 2>"$WORK/stderr")"
STATUS=$?
assert_status "config with spaces and CRLF accepted" 0
assert_json "config values are trimmed" '.metadata.top_n == 6 and .metadata.username == "TestManager"'

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
assert_json "json has metadata" '.metadata.league_id == "100000000000000001"'
assert_json "json has diagnostics" '(.diagnostics.fetches | length) > 0'
assert_json "json keys stable" \
    '[keys[]] == ["custom_trades","diagnostics","history","lineup","matchup","metadata","opportunity","player_pool","projection_sources","rosters","schema_version","trades","value_trades","waivers","warnings"]'

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
# A local HTTP server counts requests; FM_RETRY_DELAY=0 keeps retries fast.
cat > "$WORK/server.py" <<'PY'
import http.server, sys
count_file, status = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(count_file, "a") as fh:
            fh.write(self.path + "\n")
        self.send_response(status)
        self.end_headers()
        self.wfile.write(b"not found")
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
http_case() {
    # http_case <status>: sets CALLS to the number of requests made for /state/nfl
    : > "$WORK/calls"
    python3 "$WORK/server.py" "$WORK/calls" "$1" > "$WORK/port" &
    SERVER_PID=$!
    for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
    STDOUT="$(FM_API="http://127.0.0.1:$(cat "$WORK/port")" FM_RETRY_DELAY=0 \
        "$SCRIPT" --no-cache --format json 2>"$WORK/stderr")"
    STATUS=$?
    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
    CALLS="$(grep -c '/state/nfl' "$WORK/calls" | tr -d ' ')"
}
http_case 404
assert_status "404 on /state/nfl fails with data error" 4
if [ "$CALLS" = "1" ]; then pass "404 is not retried"; else fail "404 is not retried" "requested $CALLS times"; fi
http_case 503
assert_status "503 on /state/nfl fails with data error" 4
if [ "$CALLS" = "4" ]; then pass "503 is retried 3 times"; else fail "503 is retried 3 times" "requested $CALLS times"; fi
assert_match "request failure reported on stderr" "$(cat "$WORK/stderr")" 'Could not load /state/nfl'

# --------------------------------------------------------------------------
section "shared python application"
# --------------------------------------------------------------------------
# The window pre-fills from --print-config: CLI > FM_* > config file > defaults.
printf 'league_id = 555\r\ntop_n=4\nhorizon=1\n' > "$WORK/pc.env"
STDOUT="$(FM_TOP_N=8 env -u FM_LEAGUE_ID "$SCRIPT" --config "$WORK/pc.env" --horizon 2 --print-config 2>"$WORK/stderr")"
STATUS=$?
assert_status "--print-config exits 0" 0
assert_json "--print-config reads the config file" '.league_id == "555" and .config_file != null'
assert_json "--print-config: environment beats the config file" '.top_n == "8"'
assert_json "--print-config: command line beats both" '.horizon == "2"'
STDOUT="$("$SCRIPT" --horizon 9 --print-config 2>"$WORK/stderr")"
STATUS=$?
assert_status "--print-config still validates" 2

# The launcher needs only Python: no jq, curl or bash 4 on PATH.
MIN_BIN="$WORK/minbin"
mkdir -p "$MIN_BIN"
for tool in python3 dirname env date; do ln -sf "$(command -v "$tool")" "$MIN_BIN/$tool"; done
STDOUT="$(PATH="$MIN_BIN" FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/ppr_basic" /bin/bash "$SCRIPT" --no-cache -q -f json 2>"$WORK/stderr")"
STATUS=$?
assert_status "runs with only python3 on PATH (no jq or curl)" 0
assert_json "report produced without jq or curl" '.lineup.slots | length > 0'
STDOUT="$(PATH="$WORK/empty" FM_PYTHON=/nonexistent /bin/bash "$SCRIPT" --version 2>"$WORK/stderr")"
STATUS=$?
assert_status "missing python exits 3" 3
assert_match "missing python is explained" "$(cat "$WORK/stderr")" 'Python 3\.8 or newer is required'

# fm_app.py can be run directly, without the launcher.
STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/ppr_basic" python3 "$ROOT/lib/fm_app.py" --no-cache -q -f text 2>"$WORK/stderr")"
STATUS=$?
assert_status "lib/fm_app.py runs directly" 0
assert_match "direct run renders the text report" "$STDOUT" 'LINEUP - week 5'

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
assert_json "unknown name explained" '.custom_trades[1].error | test("not found on any roster in this league")'
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
section "trades between any two teams"
# --------------------------------------------------------------------------
run_case ppr_basic --format json --skip-waivers --skip-trades \
    --trade "Team2 RB1 for Team3 RB2, Team3 WR3; Team2 QB2 for Team3 QB2; Team2 WR1 for Team2 WR2; Team2 WR1, Team3 WR1 for Team4 WR1"
assert_json "trade between two other teams is graded for both" \
    '.custom_trades[0] | .side_a.roster_id == 2 and (.side_a.is_me | not) and .partner.roster_id == 3 and .my_grade == "F" and .their_grade == "A-"'
assert_json "third-party verdict names the teams" '.custom_trades[0].verdict | test("Team 3 wins this clearly; Team 2 should ask for more")'
assert_json "third-party notes use team names" '[.custom_trades[0].notes[] | select(test("would not start for Team 2"))] | length == 1'
assert_json "even swap reads as about even" '.custom_trades[1].verdict | test("About even")'
assert_json "same-team trade rejected" '.custom_trades[2].error | test("other than the giving team")'
assert_json "giving players from two teams rejected" '.custom_trades[3].error | test("players to give are on different teams")'
run_case ppr_basic --format json --skip-waivers --skip-trades --trade "Wes Delta for Team2 WR2"
assert_json "trades involving me keep you/them wording" '.custom_trades[0] | .side_a.is_me and (.verdict | test("you|your|them"))'
run_case ppr_basic --skip-waivers --skip-trades --trade "Team2 RB1 for Team3 RB2, Team3 WR3"
assert_match "text labels third-party sides by team" "$STDOUT" 'GRADE  Team 2 F   Team 3 A-'

# --------------------------------------------------------------------------
section "any-player trades"
# --------------------------------------------------------------------------
run_case ppr_basic --format json --skip-waivers --skip-trades
assert_json "no any-player section unless asked" '.value_trades == null'
assert_json "player pool lists projected players with all scorings" \
    '(.player_pool | length) == 62 and (.player_pool[0] | (.window_points | keys) == ["half","league","ppr","std"])'

run_case ppr_basic --format json --skip-waivers --skip-trades --teams 4 --scoring half \
    --value-trade "Team2 RB1 for Team3 RB2, Team4 WR3; Quinn Alpha for Team4 QB1; Free Wide One for Team2 TE2"
assert_status "any-player run exits 0" 0
assert_json "any players from any teams and free agents" \
    '.value_trades[0] | .mode == "open" and .scoring == "half" and .teams == 4 and ([.get[].team] == ["DDD","EEE"])'
assert_json "values players above replacement" \
    '.value_trades[0] | .give[0].value_over_replacement == 16 and .get[1].value_over_replacement == 0 and .replacement_levels.RB == 10.5'
assert_json "grades are mirror images" '.value_trades[0] | .my_grade == "F" and .their_grade == "A-" and .my_gain == -11'
assert_json "consolidation and roster notes" \
    '[.value_trades[0].notes[] | select(test("best player in the deal|would need to drop|below replacement"))] | length == 3'
assert_json "even swap grades C both ways" '.value_trades[1] | .my_grade == "C" and .their_grade == "C"'
assert_json "free agents can be traded in open mode" '.value_trades[2] | .error == null and .give[0].player_id == "fa_wr1"'

run_case ppr_basic --format json --skip-waivers --skip-trades --teams 4 --value-trade "Team2 RB1 for Team3 RB2"
assert_json "scoring defaults to PPR" '.value_trades[0].scoring == "ppr"'
run_case ppr_basic --format json --skip-waivers --skip-trades --value-trade "Team2 RB1 for Team3 RB2"
assert_json "a 12-team league has deeper replacement levels" '.value_trades[0] | .teams == 12 and .give[0].value_over_replacement == 64'

run_case ppr_basic --format json --skip-waivers --skip-trades \
    --value-trade "Alpha for Team2 TE1; Alpha QB for Team2 QB1; Team2 RB1 for Team2 RB1; nobody at all for Team2 TE1; Team2 TE1"
assert_json "ambiguous names list position and team" \
    '.value_trades[0].error | test("Quinn Alpha \\(QB, AAA\\)") and test("add a position or team")'
assert_json "position narrows a name" '.value_trades[1] | .error == null and .give[0].player_id == "qb1"'
assert_json "same player on both sides rejected" '.value_trades[2].error | test("already in this trade")'
assert_json "unknown player explained" '.value_trades[3].error | test("not found")'
assert_json "one-sided input explained" '.value_trades[4].error | test("side B gives")'

run_case ppr_basic --scoring bogus
assert_status "bad --scoring rejected" 2
run_case ppr_basic --teams 40
assert_status "bad --teams rejected" 2
run_case ppr_basic --skip-waivers --skip-trades --teams 4 --value-trade "Team2 RB1 for Team3 RB2, Team4 WR3"
assert_match "text shows any-player grades" "$STDOUT" 'GRADE  side A F   side B A-'
run_case ppr_basic --format markdown --skip-waivers --skip-trades --teams 4 --value-trade "Team2 RB1 for Team3 RB2, Team4 WR3"
assert_match "markdown shows any-player table" "$STDOUT" '\| Side B gives \| Pos \| Team \| Points \| Above repl. \|'

# --------------------------------------------------------------------------
section "history and projection accuracy"
# --------------------------------------------------------------------------
run_case season_history --format json
assert_status "history case exits 0" 0
assert_json "history available for weeks 1-4" '.history.available and .history.weeks == [1,2,3,4]'
assert_json "accuracy by position" '.history.accuracy.by_position | keys == ["DEF","K","QB","RB","TE","WR"]'
assert_json "every compared player-week counted" '.history.accuracy.overall.n == 237'
assert_json "missing stats feed for week 2 is reported" '.history.stats_missing_weeks == [2]'
assert_json "league points used for rostered players, stats feed for the rest" \
    '.history.actual_sources == {"league": 204, "stats": 33}'
assert_json "fading starter: recent form below projection" \
    '.history.players.wr2 | .avg_points == 7.8 and .avg_projection == 10.6 and .beat == 1 and .compared == 4'
assert_json "weekly results listed in order" '[.history.players.wr2.last[].actual] == [14,9,5,3]'
assert_json "my roster listed by recent average" '.history.my_roster[0] == "qb1" and (.history.my_roster | length) == 15'
assert_json "waiver rows carry recent form" \
    '[.waivers.groups[][] | select(.player_id == "fa_wr1") | .recent.games] == [3]'
assert_json "history diagnostic summarises the weeks" \
    '[.diagnostics.fetches[] | select(.key == "history") | .note] | .[0] | test("weeks 1-4; 0 stored, 4 fetched")'
# Independent check of the overall average miss straight from the fixture files.
MAE_EXPECTED="$(python3 - "$FIXTURES/season_history" <<'PY'
import json, os, sys
d = sys.argv[1]
errs = []
for w in (1, 2, 3, 4):
    proj = {r["player_id"]: r["stats"]["pts_ppr"] for r in json.load(open(os.path.join(d, "projections_w%d.json" % w)))}
    act = {}
    sp = os.path.join(d, "stats_w%d.json" % w)
    if os.path.exists(sp):
        act.update({r["player_id"]: r["stats"]["pts_ppr"] for r in json.load(open(sp))})
    for m in json.load(open(os.path.join(d, "matchups_w%d.json" % w))):
        act.update(m["players_points"])
    errs += [act[p] - v for p, v in proj.items() if v >= 1 and p in act]
print(round(sum(abs(e) for e in errs) / len(errs), 2))
PY
)"
assert_json "average miss matches an independent calculation" ".history.accuracy.overall.mae == $MAE_EXPECTED"

run_case season_history --format text
assert_match "text history section" "$STDOUT" 'HISTORY - weeks 1-4 \(projected vs actual, league scoring\)'
assert_match "text accuracy row" "$STDOUT" 'ALL   237   3\.1'
assert_match "text recent form row" "$STDOUT" 'Wes Bravo \(WR/BBB\) +4   7\.8    10\.6   1/4   14 9 5 3'
assert_match "text waiver form column" "$STDOUT" 'Free Wide One .*form 14\.6/16\.6'
run_case season_history --format markdown
assert_match "markdown history table" "$STDOUT" '\| ALL \| 237 \| 3\.1 \| 0 \| 81% \|'
run_case ppr_basic --format text
assert_match "no past data: history explained" "$STDOUT" 'HISTORY: unavailable - No past-week results could be loaded'
run_case ppr_basic --format json --week 1
assert_json "week 1: no completed weeks yet" '.history.available == false and (.history.reason | test("No completed weeks"))'
run_case season_history --format json --no-history
assert_json "--no-history: no history section or diagnostic" \
    '.history == null and ([.diagnostics.fetches[] | select(.key == "history")] | length == 0)'
run_case season_history --format text --no-history
assert_no_match "--no-history: no history text" "$STDOUT" '^HISTORY'

# The database: past weeks are fetched once, pre-kickoff snapshots are kept.
HDB="$WORK/history_cache"
rm -rf "$HDB"
hist_run() {
    STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/season_history" "$SCRIPT" --cache-dir "$HDB" -q -f json "$@" 2>"$WORK/stderr")"
    STATUS=$?
}
hist_run --week 4
assert_json "week 4 run: weeks 1-3 compared" '.history.weeks == [1,2,3] and .history.projection_sources.snapshot == 0'
if [ -f "$HDB/history.sqlite" ]; then pass "history database written to the cache folder"; else fail "history database written to the cache folder"; fi
hist_run
assert_json "week 5 run: week 4 compared against the pre-kickoff snapshot" \
    '.history.projection_sources == {"snapshot": 62, "backfill": 175}'
assert_json "week 5 run: weeks 1-3 come from the database" \
    '[.diagnostics.fetches[] | select(.key == "history") | .note][0] | test("3 stored, 1 fetched")'
hist_run
assert_json "third run: nothing fetched" \
    '[.diagnostics.fetches[] | select(.key == "history") | .source, .note] | .[0] == "database" and (.[1] | test("4 stored, 0 fetched"))'
FIRST_MAE="$(jq '.history.accuracy.overall' <<< "$STDOUT")"
hist_run --history-db "$WORK/other.sqlite"
if [ -f "$WORK/other.sqlite" ]; then pass "--history-db chooses the database file"; else fail "--history-db chooses the database file"; fi
assert_json "a fresh database gives backfill-only results" '.history.projection_sources.snapshot == 0'
rm -rf "$WORK/nc_history"
STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/season_history" "$SCRIPT" --cache-dir "$WORK/nc_history" --no-cache -q -f json 2>"$WORK/stderr")"
assert_json "--no-cache keeps history in memory" '.history.available and .history.projection_sources.snapshot == 0'
if [ ! -e "$WORK/nc_history/history.sqlite" ]; then pass "--no-cache writes no database"; else fail "--no-cache writes no database"; fi
if [ -n "$FIRST_MAE" ]; then pass "history accuracy readable after reruns"; else fail "history accuracy readable after reruns"; fi
FM_HISTORY=2 "$SCRIPT" --print-config >/dev/null 2>"$WORK/stderr"; STATUS=$?
assert_status "invalid FM_HISTORY rejected" 2

# Regressions from the first live run: byes are not games, and fewer snaps
# with more touches is not a lost role.
UNIT="$(python3 - "$ROOT/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fm_history as h
form = h.player_form({6: (18.0, 18.3), 7: (None, 0.0), 8: (19.0, 27.6), 9: (18.0, 13.9), 5: (17.0, 20.0)})
print(form["weeks"], form["avg_points"])
print(h.player_form({7: (0.5, 0.0)}))
print(h.classify({"snap_then": 81, "snap_now": 60, "opportunities_then": 19.5, "opportunities_now": 20.5}),
      h.classify({"snap_then": 81, "snap_now": 60, "opportunities_then": 19.5, "opportunities_now": 15.0}))
PY
)"
assert_match "recent form skips a bye (no projection, 0 points)" "$UNIT" '^\[5, 6, 8, 9\] 19\.9'
assert_match "no game at all gives no form" "$UNIT" $'\nNone\n'
assert_match "fewer snaps but more touches is not a lost role" "$UNIT" 'None declining$'

# --------------------------------------------------------------------------
section "win probability"
# --------------------------------------------------------------------------
run_case ppr_basic --format json
assert_json "win probability for both lineups" \
    '.matchup.win_probability | .simulations == 10000 and (.current_lineup_pct | . >= 0 and . <= 100) and (.recommended_lineup_pct | . >= 0 and . <= 100)'
assert_json "recommended lineup wins more often than the current one" \
    '.matchup.win_probability | .recommended_lineup_pct > .current_lineup_pct'
assert_json "ranges are ordered" '.matchup.win_probability | .my_range.p10 < .my_range.p50 and .my_range.p50 < .my_range.p90'
assert_json "median close to the projection" '(.matchup.win_probability.opponent_range.p50 - .matchup.opponent_projected) | fabs < 2'
assert_json "typical spreads without history" '.matchup.win_probability.spread_source | test("typical spreads")'
FIRST_WP="$(jq -c '.matchup.win_probability' <<< "$STDOUT")"
# Independent check: the sum of independent normal scores (same spreads)
# gives the win probability in closed form; the simulation must agree.
WP_EXPECTED="$(python3 - "$FIXTURES/ppr_basic" <<'PY'
import json, math, os, sys
d = sys.argv[1]
players = json.load(open(os.path.join(d, "players.json")))
proj = {r["player_id"]: r["stats"]["pts_ppr"] for r in json.load(open(os.path.join(d, "projections.json")))}
spread = {"QB": 6.5, "RB": 6.5, "WR": 6.5, "TE": 5.0, "K": 4.0, "DEF": 5.5}
ref = {"QB": 18.0, "RB": 12.0, "WR": 12.0, "TE": 9.0, "K": 8.0, "DEF": 7.0}
def stats(pids):
    mean = sum(proj[p] for p in pids)
    var = 0.0
    for p in pids:
        pos = players[p]["position"]
        var += (spread[pos] * min(1.6, max(0.4, math.sqrt(proj[p] / ref[pos])))) ** 2
    return mean, var
m = {e["roster_id"]: e for e in json.load(open(os.path.join(d, "matchups.json")))}
(a, va), (b, vb) = stats(m[1]["starters"]), stats(m[2]["starters"])
print(round(100 * 0.5 * (1 + math.erf((a - b) / math.sqrt(2 * (va + vb)))), 1))
PY
)"
assert_json "simulated win probability matches the closed form (within 1.5 points)" \
    "(.matchup.win_probability.current_lineup_pct - $WP_EXPECTED) | fabs < 1.5"
run_case ppr_basic --format json
if [ "$(jq -c '.matchup.win_probability' <<< "$STDOUT")" = "$FIRST_WP" ]; then
    pass "simulation is reproducible"
else
    fail "simulation is reproducible"
fi
run_case season_history --format json
assert_json "history spreads used once there are enough games" \
    '.matchup.win_probability | (.spread_source | test("projection misses for QB, RB, TE, WR")) and .spreads.QB == 3.48 and .spreads.K == 4'
assert_json "no win-probability moves in a normal week" '.matchup.win_probability.moves == []'
run_case locked_players --format json
assert_json "players whose game started count at their points" '.matchup.win_probability.fixed_players >= 1'
run_case underdog_volatile --format json
assert_json "heavy underdog: a volatile bench back raises the chance to win" \
    '.matchup.win_probability.moves[0] | .in.player_id == "rb2" and .out.player_id == "rb5" and .slot == "FLEX" and .win_gain >= 1 and .points_change == -1'
assert_json "underdog win probability is low" '.matchup.win_probability.recommended_lineup_pct < 15'
run_case underdog_volatile --format text
assert_match "text win probability" "$STDOUT" 'Win probability: [0-9.]+% with your current lineup, [0-9.]+% with the recommended one \(10000 simulations\)'
assert_match "text likely range" "$STDOUT" 'Likely range \(10th-90th percentile\): you [0-9]+-[0-9]+, them [0-9]+-[0-9]+'
assert_match "text win-probability move" "$STDOUT" 'To raise your chances: start Ryan Bravo over Ryan Echo \(FLEX\): [0-9.]+% \(\+[0-9.]+\), -1 projected points'
run_case underdog_volatile --format markdown
assert_match "markdown win probability table" "$STDOUT" '\| Win probability \| Current lineup \| Recommended lineup \|'

# --------------------------------------------------------------------------
section "opportunity trends"
# --------------------------------------------------------------------------
run_case season_history --format json
assert_json "usage trends from the stats feed (week 2 missing)" \
    '.opportunity | .available and .weeks == [1,3,4] and .sources == {"sleeper": 3}'
assert_json "breakout: free agent whose role is growing" \
    '.opportunity.breakouts | length == 1 and .[0].player_id == "fa_rb2" and .[0].snap_then == 25 and .[0].snap_now == 57 and .[0].opportunities_then == 5 and .[0].opportunities_now == 13'
assert_json "losing role: my starter's snaps and targets falling" \
    '.opportunity.declining | length == 1 and .[0].player_id == "wr2" and .[0].snap_then == 89 and .[0].snap_now == 52'
assert_json "steady players are not flagged" '[.opportunity.players[] | select(.flag != null)] | length == 1'
assert_json "my roster trends listed" '.opportunity.players | has("qb1") and has("rb1")'
run_case season_history --format text
assert_match "text breakout watch" "$STDOUT" 'Free Run Two \(RB/FFF\) +snaps 25% -> 57% +targets\+carries 5 -> 13'
assert_match "text losing role" "$STDOUT" 'Wes Bravo \(WR/BBB\) +snaps 89% -> 52% +targets\+carries 8 -> 4\.5'
run_case season_history --format markdown
assert_match "markdown breakout table" "$STDOUT" '\| Free Run Two \| RB \| FFF \| 25% -> 57% \| 5 -> 13 \|'
run_case underdog_volatile --format json
assert_json "waiver row notes a growing role" \
    '[.waivers.groups[][] | select(.player_id == "fa_wr1") | .notes[] | select(test("Role growing: snaps 45% -> 85%"))] | length == 1'
run_case ppr_basic --format json
assert_json "no usage: trends explained" '.opportunity.available == false and (.opportunity.reason | test("at least 3 past weeks"))'
run_case season_history --format json --no-history
assert_json "--no-history: no trends" '.opportunity == null'

# The stats feed is down for every week: usage comes from nflverse.
run_case usage_nflverse --format json
assert_json "nflverse fills usage for every week" '.opportunity.sources == {"nflverse": 4} and .opportunity.weeks == [1,2,3,4]'
assert_json "nflverse breakout matched by name and the LA/LAR team code" \
    '.opportunity.breakouts[0] | .player_id == "fa_rb2" and .team == "LAR" and .snap_now == 57'
assert_json "nflverse decline matched by GSIS id" '.opportunity.declining[0].player_id == "wr2"'
assert_json "nflverse downloads in diagnostics" \
    '[.diagnostics.fetches[] | select(.key | startswith("nflverse")) | .source] == ["fixture","fixture"]'
UC="$WORK/usage_cache"
rm -rf "$UC"
FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/usage_nflverse" "$SCRIPT" --cache-dir "$UC" -q -f json >/dev/null 2>&1
STDOUT="$(FM_OFFLINE=1 FM_FIXTURES="$FIXTURES/usage_nflverse" "$SCRIPT" --cache-dir "$UC" -q -f json 2>"$WORK/stderr")"
assert_json "nflverse usage is kept in the history database" \
    '.opportunity.sources == {"nflverse": 4} and ([.diagnostics.fetches[] | select(.key | startswith("nflverse"))] | length == 0)'
if [ -f "$UC/nflverse_stats_2025.csv" ]; then pass "nflverse download cached"; else fail "nflverse download cached"; fi

# --------------------------------------------------------------------------
section "rest of season and two trade grades"
# --------------------------------------------------------------------------
run_case rest_of_season --format json --horizon ros --skip-waivers --skip-trades --trade "Ryan Echo for Team2 RB1" \
    --value-trade "Team2 RB1 for Ryan Echo"
assert_status "--horizon ros exits 0" 0
assert_json "rest of season runs through the league's last playoff week" \
    '.metadata.window_weeks == [5,6,7,8,9,10,11,12,13,14,15,16,17] and .metadata.horizon_mode == "ros"'
assert_json "window labelled as rest of season" '.metadata.window_label == "rest of season (weeks 5-17)"'
assert_json "this-week grade: the new back is on bye" \
    '.custom_trades[0].grades.this_week | .week == 5 and .my_grade == "D+" and .my_gain == -1 and .their_grade == "A+"'
assert_json "rest-of-season grade: a clear win" \
    '.custom_trades[0].grades.window | .rest_of_season and .my_grade == "A" and .their_grade == "F" and .my_gain_per_week == 3.38'
assert_json "overall grade is the window grade" '.custom_trades[0] | .my_grade == .grades.window.my_grade'
assert_json "disagreeing grades are explained" \
    '[.custom_trades[0].notes[] | select(test("This week and the longer view disagree for you: -1.0 points this week \\(D\\+\\)"))] | length == 1'
assert_json "passed trade deadline flagged" \
    '[.custom_trades[0].flags[] | select(. == "The league'"'"'s trade deadline (week 4) has passed.")] | length == 1'
assert_json "any-player trade has both grades" \
    '.value_trades[0].grades | .this_week.my_grade == "A+" and .window.my_grade == "F" and .this_week.my_gain == 12'
run_case rest_of_season --format text --horizon ros --skip-waivers --skip-trades --trade "Ryan Echo for Team2 RB1"
assert_match "text shows both grades" "$STDOUT" \
    'this week \(week 5\): you D\+, them A\+ \(-1 / \+4\)   rest of season \(weeks 5-17\): you A, them F'
run_case rest_of_season --format markdown --horizon ros --skip-waivers --skip-trades --trade "Ryan Echo for Team2 RB1"
assert_match "markdown grade table" "$STDOUT" '\| Rest of season \(weeks 5-17\) \| A \(\+3\.4/wk\) \| F \(-3\.2/wk\) \|'
run_case ppr_basic --format json --horizon ROS
assert_json "ROS works in capitals; missing weeks shorten the window" \
    '.metadata.window_weeks == [5,6,7,8] and (.metadata.window_label | test("no projections after week 8 yet"))'
assert_json "missing rest-of-season weeks are listed" \
    '[.warnings[] | select(test("week\\(s\\) 9, 10, 11, 12, 13, 14, 15, 16, 17 unavailable"))] | length == 1'
run_case ppr_basic --format json --trade "Wes Delta, Ryan Echo for Team2 RB1"
assert_json "default horizon: both grades, no deadline flag" \
    '.custom_trades[0] | .grades.window.label == "weeks 5, 6, 7, 8" and ([.flags[] | select(test("deadline"))] | length == 0)'
run_case ppr_basic --format json --horizon 0 --trade "Wes Delta, Ryan Echo for Team2 RB1"
assert_json "this week only: both grades are the same week" '.custom_trades[0].grades.window.weeks == [5]'
run_case ppr_basic --horizon 9
assert_status "horizon 9 rejected" 2
assert_match "horizon message mentions ros" "$STDERR" 'between 0 and 6, or ros'
STDOUT="$("$SCRIPT" --horizon ros --print-config 2>/dev/null)"
assert_json "--print-config shows ros" '.horizon == "ros"'

# --------------------------------------------------------------------------
section "second projection source"
# --------------------------------------------------------------------------
run_case espn_compare --format json
assert_status "ESPN comparison exits 0" 0
assert_json "ESPN projections matched to Sleeper players" \
    '.projection_sources | .available and .provider == "espn" and .week == 5 and .matched == 57 and .unmatched == 5'
assert_json "matched by name and team when there is no ESPN id" '.projection_sources.compared >= 55'
assert_json "disagreements: my starter first, then a free agent" \
    '[.projection_sources.disagreements[] | [.player_id, .where, .difference]] == [["wr1","your starter",-7],["fa_rb1","free agent",6]]'
assert_json "typical gap reported" '.projection_sources.mean_abs_diff == 0.8'
assert_json "comparison alone changes no advice" '.lineup.optimal_points == 109 and .projection_sources.mode == "sleeper"'
run_case espn_compare --format json --projections blend
assert_json "blend: every window week blended" '.projection_sources.blended_weeks == [5,6,7,8] and .metadata.projections_mode == "blend"'
assert_json "blend: the starter ESPN dislikes is projected halfway between" \
    '[.lineup.slots[] | select(.recommended.player_id == "wr1") | .recommended.points] == [11.5]'
assert_json "blend changes the lineup total" '.lineup.optimal_points < 109'
run_case espn_compare --format text
assert_match "text sources section" "$STDOUT" 'PROJECTION SOURCES - Sleeper vs ESPN, week 5 \(PPR points\)'
assert_match "text disagreement row" "$STDOUT" 'Wes Alpha \(WR/AAA\) +your starter +Sleeper 15 +ESPN 8 +\(-7\)'
run_case espn_compare --format markdown
assert_match "markdown sources table" "$STDOUT" '\| Free Run One \| RB \| EEE \| free agent \| 12 \| 18 \| \+6 \|'
run_case ppr_basic --format json
assert_json "no ESPN data: explained, advice unchanged" \
    '.projection_sources.available == false and ([.diagnostics.fetches[] | select(.key == "espn") | .source] == ["unavailable"])'
run_case ppr_basic --format json --projections blend
assert_json "blend without ESPN data warns and uses Sleeper" \
    '([.warnings[] | select(test("blend uses Sleeper only"))] | length == 1) and .projection_sources.blended_weeks == []'
run_case espn_compare --format json --compare none
assert_json "--compare none: no second source" '.projection_sources == null and ([.diagnostics.fetches[] | select(.key == "espn")] | length == 0)'
run_case ppr_basic --compare yahoo
assert_status "unknown second source rejected" 2
run_case ppr_basic --projections blend --compare none
assert_status "blend needs a second source" 2
assert_match "blend without a source explained" "$STDERR" 'needs a second source'
# The ESPN parser on its own: response shapes, D/ST by team, other stat rows ignored.
PARSED="$(python3 - "$ROOT/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fm_providers as p
players = {"buf_wr": {"full_name": "Joe Example Jr.", "team": "BUF", "position": "WR"},
           "BUF": {"full_name": "Buffalo", "team": "BUF", "position": "DEF"},
           "e1": {"full_name": "Id Match", "team": "MIA", "position": "RB", "espn_id": 77}}
week_rows = lambda w, pts: [{"statSourceId": 0, "statSplitTypeId": 1, "scoringPeriodId": w, "appliedTotal": 50},
                            {"statSourceId": 1, "statSplitTypeId": 0, "scoringPeriodId": 0, "appliedTotal": 200},
                            {"statSourceId": 1, "statSplitTypeId": 1, "scoringPeriodId": w, "appliedTotal": pts}]
payload = {"players": [
    {"player": {"id": 1, "fullName": "Joe Example", "defaultPositionId": 3, "proTeamId": 2, "stats": week_rows(9, 14.2)}},
    {"player": {"id": -16002, "fullName": "Bills D/ST", "defaultPositionId": 16, "proTeamId": 2, "stats": week_rows(9, 7.0)}},
    {"player": {"id": 77, "fullName": "Renamed", "defaultPositionId": 2, "proTeamId": 15, "stats": week_rows(9, 11.0)}},
    {"player": {"id": 5, "fullName": "Nobody", "defaultPositionId": 3, "proTeamId": 3, "stats": week_rows(9, 9.0)}},
    {"player": {"id": 6, "fullName": "Wrong Week", "defaultPositionId": 3, "proTeamId": 2, "stats": week_rows(8, 9.0)}}]}
payload["players"][0]["player"]["stats"].insert(0, {"statSourceId": 1, "statSplitTypeId": 1, "scoringPeriodId": 9,
                                                   "externalId": "20259", "appliedTotal": 88.0})
points, matched, unmatched = p.parse_espn(payload, 9, players, "2026")
print(sorted(points.items()), matched, unmatched)
print(p.parse_espn(payload["players"], 9, players)[1], p.parse_espn({"oops": 1}, 9, players)[1])
print(p.blend_factor(10, 30), p.blend_factor(0.2, 5), p.disagrees(3, 6), p.disagrees(20, 25))
PY
)"
assert_match "parser: id, name (suffix-insensitive) and D/ST matches" "$PARSED" "\[\('BUF', 7\.0\), \('buf_wr', 14\.2\), \('e1', 11\.0\)\] 3 \['Nobody'\]"
assert_match "parser: plain list accepted, bad shape ignored" "$PARSED" $'\n3 0\n'
assert_match "parser: blend limits and disagreement rule" "$PARSED" '1\.5 None False False'
FILTER="$(python3 -c "import sys; sys.path.insert(0, '$ROOT/lib'); import fm_providers as p; print(p.espn_filter('2026', 10))")"
assert_match "ESPN filter asks for the week's projections by period code" "$FILTER" '"additionalValue":\["002026","102026","11202610","01202610"\]'
assert_no_match "ESPN filter has no stat filters that drop weekly rows" "$FILTER" 'filterStatsForSourceIds|filterStatsForSplitTypeIds|filterStatsForExternalIds'

# --------------------------------------------------------------------------
section "ESPN leagues"
# --------------------------------------------------------------------------
ESPN_ARGS=(--platform espn --league-id 555001)
run_case espn_league "${ESPN_ARGS[@]}" --team "Test Titans" --format json
assert_status "ESPN league exits 0" 0
assert_json "ESPN league: platform, team and roster" \
    '.metadata.platform == "espn" and .metadata.team_name == "Test Titans" and .metadata.roster_id == 1 and .metadata.league_name == "ESPN Test League"'
assert_json "ESPN lineup slots converted (D/ST and K included)" \
    '.metadata.starting_slots == ["QB","RB","RB","WR","WR","TE","FLEX","DEF","K"]'
assert_json "ESPN roster and current lineup read" \
    '.lineup.current_points == 101 and ([.lineup.slots[] | select(.slot == "QB") | .current.player_id] == ["qb1"])'
assert_json "kickers and defenses use ESPN's league-scored projections" \
    '.metadata.scoring.host_scored == {"provider": "espn", "positions": ["DEF","K"]}
     and ([.lineup.slots[] | select(.slot == "K" or .slot == "DEF") | .recommended.points] == [8.5, 9.5])'
assert_json "offense scored with the converted ESPN rules" '.lineup.optimal_points == 114'
assert_json "a player with no ESPN id is matched by name" \
    '[.lineup.slots[] | select(.recommended.player_id == "wr3")] | length == 1'
assert_json "ESPN waiver settings converted" '.waivers.waiver.type == "waiver priority" and .waivers.waiver.budget == null'
assert_json "ESPN matchup and opponent" '.matchup.my_team == "Test Titans" and .matchup.opponent_team == "Team 2"'
assert_json "unmapped ESPN scoring item reported" \
    '[.warnings[] | select(test("1 ESPN scoring item\\(s\\) have no projected stat.*100-199 yard rushing game"))] | length == 1'
assert_json "ESPN-only player reported, still on the roster" \
    '([.warnings[] | select(test("not in the player database.*Espn Only"))] | length == 1)
     and ([.rosters[] | select(.roster_id == 2) | .players[] | select(.name == "Espn Only")] | length == 1)'
assert_json "missing ESPN kicker/defense week reported" \
    '[.warnings[] | select(test("unavailable for week\\(s\\) 8"))] | length == 1'
assert_json "ESPN league data in the diagnostics, no Sleeper league calls" \
    '([.diagnostics.fetches[] | select(.key == "espn_league" or .key == "espn_matchups" or .key == "espn_host") | .source] == ["fixture","fixture","fixture"])
     and ([.diagnostics.fetches[] | select(.key == "league" or .key == "rosters" or .key == "user")] | length == 0)'
run_case espn_league "${ESPN_ARGS[@]}" --team tt --format text
assert_match "team found by abbreviation; text header names the platform" "$STDOUT" 'ESPN league 555001 +Team: Test Titans'
assert_match "text scoring line names the host-scored positions" "$STDOUT" "DEF and K: ESPN's league-scored projections"
run_case espn_league "${ESPN_ARGS[@]}" --team 2 --format markdown
assert_match "team found by id; markdown header" "$STDOUT" '^- ESPN league 555001 - Team: Team 2$'
run_case espn_league "${ESPN_ARGS[@]}" --team "titans" --format json --trade "Wes Bravo for id:t2_rb1"
assert_json "team found by part of its name; trade graded with the deadline flagged" \
    '.custom_trades[0].my_grade != null and ([.custom_trades[0].flags[] | select(test("trade deadline .* has passed"))] | length == 1)'
run_case espn_league "${ESPN_ARGS[@]}" --team "Test Titans" --format json --horizon ros
assert_json "rest of season runs to ESPN's final scoring period" '.metadata.horizon_mode == "ros" and .metadata.window_weeks[0] == 5'
run_case espn_league "${ESPN_ARGS[@]}" --team team
assert_status "ambiguous team name rejected" 4
assert_match "ambiguous team: the teams are listed" "$STDERR" 'Teams: Test Titans; Team 2; Team 3; Team 4'
run_case espn_league "${ESPN_ARGS[@]}"
assert_status "ESPN league without --team rejected" 2
assert_match "missing team explained" "$STDERR" 'needs your team'
run_case espn_league --platform yahoo
assert_status "unknown platform rejected" 2
run_case ppr_basic --platform espn --league-id 555001 --team x
assert_status "ESPN league that can't be read exits 4" 4
assert_match "unreadable ESPN league explained" "$STDERR" 'ESPN league 555001 could not be loaded'
STDOUT="$("$SCRIPT" --platform espn --team "My Team" --print-config 2>/dev/null)"
assert_json "--print-config shows platform and team" '.platform == "espn" and .team == "My Team"'
run_case ppr_basic --format json
assert_json "Sleeper leagues report their platform" '.metadata.platform == "sleeper" and .metadata.scoring.host_scored == null'
# The ESPN converter on its own: scoring items, slots and team lookup.
CONVERTED="$(python3 - "$ROOT/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fm_espn as e
items = [{"statId": 53, "points": 0.5, "pointsOverrides": {"6": 1.0}}, {"statId": 3, "points": 0.04},
         {"statId": 80, "points": 3.0}, {"statId": 198, "points": 5.0}, {"statId": 99, "points": 0.0, "pointsOverrides": {"16": 1.0}},
         {"statId": 17, "points": 2.0}, {"statId": 92, "points": 0.0, "pointsOverrides": {"16": 1.0}}, {"statId": 4, "points": 0}]
scoring, unmapped = e.convert_scoring(items)
print(sorted(scoring.items()))
print(unmapped)
doc = {"id": 9, "status": {"finalScoringPeriod": 17},
       "settings": {"name": "L", "size": 2, "rosterSettings": {"lineupSlotCounts": {"0": 1, "7": 1, "5": 1, "19": 1, "20": 2, "21": 1}},
                    "acquisitionSettings": {"isUsingAcquisitionBudget": True, "acquisitionBudget": 200}},
       "teams": [{"id": 3, "name": "Alpha Dogs", "abbrev": "AD"}, {"id": 4, "name": "Beta Dogs", "abbrev": "BD"}]}
league, notes = e.convert_league(doc)
print(league["roster_positions"], league["settings"]["waiver_type"], league["settings"]["waiver_budget"],
      league["settings"]["last_scoring_week"], len(notes))
find = lambda text: (e.find_team(doc, text)[0] or {}).get("id")
print(find("4"), find("alpha dogs"), find("bd"), find("beta"), find("dogs"), find(""))
PY
)"
assert_match "converter: TE premium, FG buckets, 50-59 as 50+, D/ST slot points" "$CONVERTED" \
    "\('bonus_rec_te', 0\.5\), \('fgm_0_19', 3\.0\), \('fgm_20_29', 3\.0\), \('fgm_30_39', 3\.0\), \('fgm_50p', 5\.0\), \('pass_yd', 0\.04\), \('rec', 0\.5\), \('sack', 1\.0\)\]"
assert_match "converter: only offensive items without a stat are reported" "$CONVERTED" "\['300-399 yard passing game \(\+2\)'\]"
assert_match "converter: slots, FAAB, final week and an unsupported slot" "$CONVERTED" \
    "\['QB', 'REC_FLEX', 'SUPER_FLEX', 'BN', 'BN', 'IR'\] 2 200 17 1"
assert_match "converter: team by id, name, abbreviation or unique part" "$CONVERTED" '4 3 4 4 None None'

# --------------------------------------------------------------------------
printf '\n%s\n' "------------------------------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'failed tests:\n'
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
exit 0
