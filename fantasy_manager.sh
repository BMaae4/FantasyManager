#!/usr/bin/env bash
#
# fantasy_manager.sh - Sleeper weekly decision-support tool (lineup, waivers, trades).
#
# Read-only: this tool NEVER submits lineups, waiver claims or trades.
# Dependencies: bash 4+, curl, jq, python3 (standard library only).
#
set -euo pipefail

TOOL_NAME="fantasy_manager"
TOOL_VERSION="2.0.0"

# --------------------------------------------------------------------------
# Hardcoded defaults (run with no parameters)
# --------------------------------------------------------------------------
DEFAULT_LEAGUE_ID="1400680781302525952"
DEFAULT_USERNAME="MaTrasaMaae"
DEFAULT_API="https://api.sleeper.app/v1"
DEFAULT_PROJECTIONS_BASE="https://api.sleeper.app/projections/nfl"
DEFAULT_SEASON_TYPE="regular"
DEFAULT_TOP_N="10"
DEFAULT_FORMAT="text"
DEFAULT_OUTPUT="-"
DEFAULT_CHURN_THRESHOLD="0.5"
DEFAULT_FAIRNESS="0.10"
DEFAULT_LOG_LEVEL="INFO"
DEFAULT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fantasy_manager"
DEFAULT_PLAYERS_TTL="86400"     # 24h
DEFAULT_PROJECTIONS_TTL="21600" # 6h
DEFAULT_TRENDING_TTL="21600"    # 6h
DEFAULT_STALE_MAX_AGE="604800"  # 7 days: oldest cache still usable as a fallback
DEFAULT_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/fantasy_manager/config.env"

# --------------------------------------------------------------------------
# Runtime state
# --------------------------------------------------------------------------
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
TMP_DIR=""
WARNINGS=()
DIAGNOSTICS_FILE=""
FETCH_SOURCE=""
FETCH_AGE="null"
CURL_FAIL_FLAG="--fail"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ANALYSIS_PY="$SCRIPT_DIR/lib/fm_analysis.py"

# Exit codes
EX_OK=0
EX_USAGE=2
EX_DEPENDENCY=3
EX_DATA=4

# --------------------------------------------------------------------------
# Logging (diagnostics on stderr, clean report on stdout)
# --------------------------------------------------------------------------
log_level_value() {
    case "$1" in
        ERROR) echo 0 ;;
        WARN)  echo 1 ;;
        INFO)  echo 2 ;;
        DEBUG) echo 3 ;;
        QUIET) echo -1 ;;
        *)     echo 2 ;;
    esac
}

redact() {
    # Redact anything that looks like a token/secret even though the public
    # Sleeper API is unauthenticated today.
    sed -E \
        -e 's/(([Tt]oken|[Ss]ecret|[Aa]pi[_-]?[Kk]ey|[Aa]uthorization|[Pp]assword)["'\'']?[[:space:]]*[:=][[:space:]]*["'\'']?)[^"'\''[:space:],}]+/\1***REDACTED***/g' \
        -e 's/([?&](access_token|api_key|token|key)=)[^&[:space:]]+/\1***REDACTED***/g'
}

log() {
    local level="$1"
    shift
    local want cur
    want="$(log_level_value "$level")"
    cur="$(log_level_value "$LOG_LEVEL")"
    if [ "$want" -le "$cur" ]; then
        printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" \
            | redact >&2
    fi
}

log_error() { log ERROR "$@"; }
log_warn()  { log WARN "$@"; }
log_info()  { log INFO "$@"; }
log_debug() { log DEBUG "$@"; }

add_warning() {
    WARNINGS+=("$1")
    log_warn "$1"
}

die() {
    local code="$1"
    shift
    log_error "$*"
    exit "$code"
}

usage() {
    cat <<'USAGE'
fantasy_manager.sh - Sleeper weekly decision support (lineup / waivers / trades)

Usage: fantasy_manager.sh [options]

Data options:
  -l, --league-id ID       Sleeper league id (default: 1400680781302525952)
  -u, --username NAME      Sleeper username (default: MaTrasaMaae)
  -w, --week N             NFL week, 1-18 (default: current week from /state/nfl)
  -s, --season YYYY        Season (default: current season from /state/nfl)
      --season-type TYPE   regular|pre|post (default: regular)
  -n, --top N              Number of ranked rows per section, 1-50 (default: 10)

Analysis options:
      --threshold X        Suppress lineup churn below X projected points (default: 0.5)
      --fairness X         Trade fairness tolerance as a fraction (default: 0.10)
      --skip-waivers       Skip waiver analysis
      --skip-trades        Skip trade analysis

Output options:
  -f, --format FORMAT      text|json|markdown (default: text)
  -o, --output PATH        Write report to PATH (default: stdout)
  -q, --quiet              Errors only on stderr
  -v, --verbose            INFO diagnostics (default)
      --debug              DEBUG diagnostics, including effective configuration
      --log-file PATH      Also append diagnostics to PATH

Cache / network options:
      --cache-dir DIR      Cache directory (default: ~/.cache/fantasy_manager)
      --cache-ttl SECONDS  Projection cache TTL in seconds (default: 21600)
      --no-cache           Ignore and do not write caches
      --refresh            Force refresh of cached data
      --offline            Never touch the network; read fixtures (--fixtures)
      --fixtures DIR       Fixture directory used by --offline

Other:
  -h, --help               Show this help
  -V, --version            Show version

Configuration precedence: CLI options > environment (FM_*) > config file > defaults.
Config file: ~/.config/fantasy_manager/config.env (KEY=VALUE lines), override with FM_CONFIG_FILE.

This tool is read-only. It cannot submit lineups, waivers or trades.
USAGE
}

# --------------------------------------------------------------------------
# Argument parsing (validate before shifting)
# --------------------------------------------------------------------------
declare -A CLI=()

need_value() {
    # need_value <option> <count-of-remaining-args>
    if [ "$2" -lt 2 ]; then
        usage >&2
        die "$EX_USAGE" "Option '$1' requires a value."
    fi
}

set_cli() {
    local key="$1" value="$2"
    if [ -n "${CLI[$key]+set}" ]; then
        log_debug "Duplicate option '$key': '${CLI[$key]}' -> '$value' (last value wins)"
    fi
    CLI["$key"]="$value"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -l|--league-id)  need_value "$1" $#; set_cli league_id "$2"; shift 2 ;;
            -u|--username)   need_value "$1" $#; set_cli username "$2"; shift 2 ;;
            -w|--week)       need_value "$1" $#; set_cli week "$2"; shift 2 ;;
            -s|--season)     need_value "$1" $#; set_cli season "$2"; shift 2 ;;
            --season-type)   need_value "$1" $#; set_cli season_type "$2"; shift 2 ;;
            -n|--top)        need_value "$1" $#; set_cli top_n "$2"; shift 2 ;;
            --threshold)     need_value "$1" $#; set_cli threshold "$2"; shift 2 ;;
            --fairness)      need_value "$1" $#; set_cli fairness "$2"; shift 2 ;;
            --skip-waivers)  set_cli skip_waivers 1; shift ;;
            --skip-trades)   set_cli skip_trades 1; shift ;;
            -f|--format)     need_value "$1" $#; set_cli format "$2"; shift 2 ;;
            -o|--output)     need_value "$1" $#; set_cli output "$2"; shift 2 ;;
            -q|--quiet)      set_cli log_level QUIET; shift ;;
            -v|--verbose)    set_cli log_level INFO; shift ;;
            --debug)         set_cli log_level DEBUG; shift ;;
            --log-file)      need_value "$1" $#; set_cli log_file "$2"; shift 2 ;;
            --cache-dir)     need_value "$1" $#; set_cli cache_dir "$2"; shift 2 ;;
            --cache-ttl)     need_value "$1" $#; set_cli projections_ttl "$2"; shift 2 ;;
            --no-cache)      set_cli no_cache 1; shift ;;
            --refresh)       set_cli refresh 1; shift ;;
            --offline)       set_cli offline 1; shift ;;
            --fixtures)      need_value "$1" $#; set_cli fixtures "$2"; shift 2 ;;
            --config)        need_value "$1" $#; set_cli config_file "$2"; shift 2 ;;
            -h|--help)       usage; exit "$EX_OK" ;;
            -V|--version)    printf '%s %s\n' "$TOOL_NAME" "$TOOL_VERSION"; exit "$EX_OK" ;;
            --)              shift; break ;;
            -*)              usage >&2; die "$EX_USAGE" "Unknown option '$1'." ;;
            *)               usage >&2; die "$EX_USAGE" "Unexpected argument '$1'." ;;
        esac
    done
    if [ $# -gt 0 ]; then
        usage >&2
        die "$EX_USAGE" "Unexpected argument '$1'."
    fi
}

# --------------------------------------------------------------------------
# Configuration resolution: CLI > env > config file > defaults
# --------------------------------------------------------------------------
declare -A CFG_FILE_VALUES=()

load_config_file() {
    local file="$1"
    [ -n "$file" ] || return 0
    [ -f "$file" ] || { log_debug "No config file at $file"; return 0; }
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" != "$line" ] || continue
        key="$(printf '%s' "$key" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        key="${key#fm_}"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        CFG_FILE_VALUES["$key"]="$value"
    done < "$file"
    log_debug "Loaded config file $file (${#CFG_FILE_VALUES[@]} keys)"
}

resolve() {
    # resolve <key> <env-var> <default>
    local key="$1" env_var="$2" default="$3" value
    if [ -n "${CLI[$key]+set}" ]; then
        value="${CLI[$key]}"
    elif [ -n "${!env_var:-}" ]; then
        value="${!env_var}"
    elif [ -n "${CFG_FILE_VALUES[$key]+set}" ]; then
        value="${CFG_FILE_VALUES[$key]}"
    else
        value="$default"
    fi
    printf '%s' "$value"
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_number() {
    printf '%s' "$1" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'
}

validate_config() {
    if ! is_uint "$LEAGUE_ID"; then
        die "$EX_USAGE" "League id must be a non-empty numeric string (got '$LEAGUE_ID')."
    fi
    [ -n "$USERNAME" ] \
        || die "$EX_USAGE" "Username must not be empty."
    if [ -n "$WEEK" ]; then
        if ! is_uint "$WEEK" || [ "$WEEK" -lt 1 ] || [ "$WEEK" -gt 18 ]; then
            die "$EX_USAGE" "Week must be an integer between 1 and 18 (got '$WEEK')."
        fi
    fi
    if [ -n "$SEASON" ]; then
        if ! is_uint "$SEASON" || [ "${#SEASON}" -ne 4 ]; then
            die "$EX_USAGE" "Season must be a 4 digit year (got '$SEASON')."
        fi
    fi
    case "$SEASON_TYPE" in
        regular|pre|post) ;;
        *) die "$EX_USAGE" "Season type must be regular, pre or post (got '$SEASON_TYPE')." ;;
    esac
    if ! is_uint "$TOP_N" || [ "$TOP_N" -lt 1 ] || [ "$TOP_N" -gt 50 ]; then
        die "$EX_USAGE" "Top N must be an integer between 1 and 50 (got '$TOP_N')."
    fi
    is_number "$CHURN_THRESHOLD" \
        || die "$EX_USAGE" "Threshold must be numeric (got '$CHURN_THRESHOLD')."
    is_number "$FAIRNESS" \
        || die "$EX_USAGE" "Fairness must be numeric (got '$FAIRNESS')."
    is_uint "$PROJECTIONS_TTL" \
        || die "$EX_USAGE" "Cache TTL must be a non-negative integer (got '$PROJECTIONS_TTL')."
    case "$FORMAT" in
        text|json|markdown) ;;
        *) die "$EX_USAGE" "Format must be text, json or markdown (got '$FORMAT')." ;;
    esac
    case "$LOG_LEVEL" in
        QUIET|ERROR|WARN|INFO|DEBUG) ;;
        *) die "$EX_USAGE" "Log level must be QUIET, ERROR, WARN, INFO or DEBUG (got '$LOG_LEVEL')." ;;
    esac
    if [ "$OFFLINE" = "1" ]; then
        [ -n "$FIXTURE_DIR" ] \
            || die "$EX_USAGE" "--offline requires --fixtures DIR (or FM_FIXTURES)."
        [ -d "$FIXTURE_DIR" ] \
            || die "$EX_USAGE" "Fixture directory '$FIXTURE_DIR' does not exist."
    fi
}

load_configuration() {
    CONFIG_FILE="$(resolve config_file FM_CONFIG_FILE "$DEFAULT_CONFIG_FILE")"
    load_config_file "$CONFIG_FILE"

    LEAGUE_ID="$(resolve league_id FM_LEAGUE_ID "$DEFAULT_LEAGUE_ID")"
    USERNAME="$(resolve username FM_USERNAME "$DEFAULT_USERNAME")"
    API="$(resolve api FM_API "$DEFAULT_API")"
    PROJECTIONS_BASE="$(resolve projections_base FM_PROJECTIONS_BASE "$DEFAULT_PROJECTIONS_BASE")"
    WEEK="$(resolve week FM_WEEK "")"
    SEASON="$(resolve season FM_SEASON "")"
    SEASON_TYPE="$(resolve season_type FM_SEASON_TYPE "$DEFAULT_SEASON_TYPE")"
    TOP_N="$(resolve top_n FM_TOP_N "$DEFAULT_TOP_N")"
    CHURN_THRESHOLD="$(resolve threshold FM_THRESHOLD "$DEFAULT_CHURN_THRESHOLD")"
    FAIRNESS="$(resolve fairness FM_FAIRNESS "$DEFAULT_FAIRNESS")"
    SKIP_WAIVERS="$(resolve skip_waivers FM_SKIP_WAIVERS "0")"
    SKIP_TRADES="$(resolve skip_trades FM_SKIP_TRADES "0")"
    FORMAT="$(resolve format FM_FORMAT "$DEFAULT_FORMAT")"
    OUTPUT="$(resolve output FM_OUTPUT "$DEFAULT_OUTPUT")"
    LOG_LEVEL="$(resolve log_level FM_LOG_LEVEL "$DEFAULT_LOG_LEVEL")"
    LOG_FILE="$(resolve log_file FM_LOG_FILE "")"
    CACHE_DIR="$(resolve cache_dir FM_CACHE_DIR "$DEFAULT_CACHE_DIR")"
    PLAYERS_TTL="$(resolve players_ttl FM_PLAYERS_TTL "$DEFAULT_PLAYERS_TTL")"
    PROJECTIONS_TTL="$(resolve projections_ttl FM_PROJECTIONS_TTL "$DEFAULT_PROJECTIONS_TTL")"
    TRENDING_TTL="$(resolve trending_ttl FM_TRENDING_TTL "$DEFAULT_TRENDING_TTL")"
    STALE_MAX_AGE="$(resolve stale_max_age FM_STALE_MAX_AGE "$DEFAULT_STALE_MAX_AGE")"
    NO_CACHE="$(resolve no_cache FM_NO_CACHE "0")"
    REFRESH="$(resolve refresh FM_REFRESH "0")"
    OFFLINE="$(resolve offline FM_OFFLINE "0")"
    FIXTURE_DIR="$(resolve fixtures FM_FIXTURES "")"

    validate_config

    log_debug "Effective configuration:"
    log_debug "  league_id=$LEAGUE_ID username=$USERNAME api=$API"
    log_debug "  projections_base=$PROJECTIONS_BASE season=${SEASON:-auto} week=${WEEK:-auto} season_type=$SEASON_TYPE"
    log_debug "  top_n=$TOP_N threshold=$CHURN_THRESHOLD fairness=$FAIRNESS"
    log_debug "  format=$FORMAT output=$OUTPUT log_level=$LOG_LEVEL log_file=${LOG_FILE:-none}"
    log_debug "  cache_dir=$CACHE_DIR projections_ttl=$PROJECTIONS_TTL no_cache=$NO_CACHE refresh=$REFRESH"
    log_debug "  offline=$OFFLINE fixtures=${FIXTURE_DIR:-none} config_file=$CONFIG_FILE"
    log_debug "  skip_waivers=$SKIP_WAIVERS skip_trades=$SKIP_TRADES"
}

# --------------------------------------------------------------------------
# Runtime / dependencies
# --------------------------------------------------------------------------
install_hint() {
    local pkg="$1"
    if command -v brew >/dev/null 2>&1; then
        printf 'brew install %s' "$pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        printf 'sudo apt-get install -y %s' "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        printf 'sudo dnf install -y %s' "$pkg"
    elif command -v pacman >/dev/null 2>&1; then
        printf 'sudo pacman -S %s' "$pkg"
    elif command -v apk >/dev/null 2>&1; then
        printf 'apk add %s' "$pkg"
    else
        printf 'install %s with your package manager' "$pkg"
    fi
}

check_dependencies() {
    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        die "$EX_DEPENDENCY" "Bash 4 or newer is required (running ${BASH_VERSION:-unknown}). Try: $(install_hint bash)"
    fi
    local missing=0 cmd
    for cmd in jq python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Missing dependency '$cmd'. Try: $(install_hint "$cmd")"
            missing=1
        fi
    done
    if [ "$OFFLINE" != "1" ] && ! command -v curl >/dev/null 2>&1; then
        log_error "Missing dependency 'curl'. Try: $(install_hint curl)"
        missing=1
    fi
    [ "$missing" -eq 0 ] || exit "$EX_DEPENDENCY"
    [ -f "$ANALYSIS_PY" ] \
        || die "$EX_DEPENDENCY" "Analysis helper not found at $ANALYSIS_PY"
    if [ "$OFFLINE" != "1" ] && curl --help all 2>/dev/null | grep -q -- '--fail-with-body'; then
        CURL_FAIL_FLAG="--fail-with-body"
    fi
    log_debug "jq $(jq --version 2>/dev/null), python3 $(python3 --version 2>&1), curl flag $CURL_FAIL_FLAG"
}

init_runtime() {
    umask 077
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fantasy_manager.XXXXXX")"
    trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
    DIAGNOSTICS_FILE="$TMP_DIR/diagnostics.json"
    printf '[]\n' > "$DIAGNOSTICS_FILE"
    if [ "$NO_CACHE" != "1" ]; then
        mkdir -p "$CACHE_DIR" || die "$EX_DATA" "Cannot create cache directory '$CACHE_DIR'."
    fi
    if [ -n "$LOG_FILE" ]; then
        mkdir -p "$(dirname -- "$LOG_FILE")" 2>/dev/null || true
        exec 2> >(tee -a -- "$LOG_FILE" >&2)
    fi
    log_debug "Temporary workspace: $TMP_DIR"
}

file_mtime() {
    # Portable modification time in epoch seconds (GNU and BSD/macOS).
    local file="$1"
    if stat -c %Y -- "$file" >/dev/null 2>&1; then
        stat -c %Y -- "$file"
    elif stat -f %m -- "$file" >/dev/null 2>&1; then
        stat -f %m -- "$file"
    else
        python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$file"
    fi
}

now_epoch() { date -u +%s; }
now_iso()   { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

record_diagnostic() {
    # record_diagnostic <key> <url> <source> <age|null> <records|null> <note>
    local tmp="$TMP_DIR/diag.$$.json"
    jq --arg key "$1" --arg url "$2" --arg source "$3" \
       --argjson age "$4" --argjson records "$5" --arg note "$6" \
       --arg at "$(now_iso)" \
       '. + [{key:$key, url:$url, source:$source, cache_age_seconds:$age, records:$records, note:$note, at:$at}]' \
       "$DIAGNOSTICS_FILE" > "$tmp" && mv -- "$tmp" "$DIAGNOSTICS_FILE"
}

# --------------------------------------------------------------------------
# Cache helpers (atomic writes, advisory lock)
# --------------------------------------------------------------------------
cache_path() { printf '%s/%s.json' "$CACHE_DIR" "$1"; }

cache_age() {
    local file="$1" mtime
    mtime="$(file_mtime "$file")"
    echo $(( $(now_epoch) - mtime ))
}

cache_store() {
    # cache_store <cache-name> <source-file>
    local name="$1" src="$2" dest tmp
    [ "$NO_CACHE" = "1" ] && return 0
    [ -n "$name" ] && [ "$name" != "-" ] || return 0
    dest="$(cache_path "$name")"
    tmp="${dest}.tmp.$$"
    mkdir -p "$CACHE_DIR"
    if command -v flock >/dev/null 2>&1; then
        (
            exec 9>"$CACHE_DIR/.lock"
            flock 9
            cp -- "$src" "$tmp" && mv -- "$tmp" "$dest"
        )
    else
        cp -- "$src" "$tmp" && mv -- "$tmp" "$dest"
    fi
    log_debug "Cached $name -> $dest"
}

# --------------------------------------------------------------------------
# JSON validation
# --------------------------------------------------------------------------
require_json_type() {
    # require_json_type <file> <object|array> <label>
    local file="$1" want="$2" label="$3" actual
    if ! jq -e . "$file" >/dev/null 2>&1; then
        log_debug "$label: response is not valid JSON (first 120 bytes: $(head -c 120 -- "$file" | tr -d '\n' | redact))"
        return 1
    fi
    actual="$(jq -r 'type' "$file")"
    if [ "$actual" != "$want" ]; then
        log_debug "$label: expected JSON $want, got $actual"
        return 1
    fi
    if [ "$want" = "array" ] && [ "$(jq -r 'length' "$file")" = "0" ]; then
        log_debug "$label: array is empty"
        return 1
    fi
    if [ "$want" = "object" ] && [ "$(jq -r 'length' "$file")" = "0" ]; then
        log_debug "$label: object is empty"
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------------
# Network layer: fetch / cache / validate only
# --------------------------------------------------------------------------
fetch_offline() {
    # fetch_offline <key> <dest>
    local key="$1" dest="$2" status_file="$FIXTURE_DIR/$1.status" src="$FIXTURE_DIR/$1.json"
    if [ -f "$status_file" ]; then
        local status
        status="$(tr -d '[:space:]' < "$status_file")"
        log_debug "Fixture $key simulates HTTP $status"
        return 1
    fi
    [ -f "$src" ] || { log_debug "Fixture $key missing at $src"; return 1; }
    cp -- "$src" "$dest"
    return 0
}

fetch_url() {
    # fetch_url <url> <dest>; returns non-zero on transport/HTTP failure
    local url="$1" dest="$2" status
    status="$(curl --silent --show-error --location "$CURL_FAIL_FLAG" \
        --connect-timeout 10 --max-time 45 \
        --retry 3 --retry-delay 1 --retry-max-time 90 --retry-all-errors \
        --write-out '%{http_code}' --output "$dest" \
        --header 'Accept: application/json' \
        --user-agent "$TOOL_NAME/$TOOL_VERSION" \
        -- "$url" 2>"$TMP_DIR/curl.err")" || {
            local err
            err="$(head -c 300 -- "$TMP_DIR/curl.err" | tr -d '\n' | redact)"
            log_debug "HTTP failure for $url (status ${status:-none}): ${err:-no message}; body: $(head -c 200 -- "$dest" 2>/dev/null | tr -d '\n' | redact)"
            return 1
        }
    log_debug "HTTP $status $url ($(wc -c < "$dest" | tr -d ' ') bytes)"
    return 0
}

fetch_json() {
    # fetch_json <key> <url> <object|array> <cache-name|-> <ttl> <allow-stale 0|1>
    # Writes validated JSON to $TMP_DIR/<key>.json; sets FETCH_SOURCE/FETCH_AGE.
    local key="$1" url="$2" want="$3" cache_name="$4" ttl="$5" allow_stale="${6:-0}"
    local dest="$TMP_DIR/$key.json" raw="$TMP_DIR/$key.raw" cfile=""
    FETCH_SOURCE=""
    FETCH_AGE="null"

    if [ -n "$cache_name" ] && [ "$cache_name" != "-" ] && [ "$NO_CACHE" != "1" ]; then
        cfile="$(cache_path "$cache_name")"
    fi

    # 1. fresh cache
    if [ -n "$cfile" ] && [ -f "$cfile" ] && [ "$REFRESH" != "1" ]; then
        local age
        age="$(cache_age "$cfile")"
        if [ "$age" -le "$ttl" ] && require_json_type "$cfile" "$want" "cache:$key"; then
            cp -- "$cfile" "$dest"
            FETCH_SOURCE="cache"
            FETCH_AGE="$age"
            log_info "Using cached $key (age ${age}s)"
            record_diagnostic "$key" "$url" "cache" "$age" "$(jq -r 'length' "$dest")" "fresh cache"
            return 0
        fi
    fi

    # 2. fetch
    local ok=1
    if [ "$OFFLINE" = "1" ]; then
        fetch_offline "$key" "$raw" && ok=0 || ok=1
    else
        log_info "Fetching $key from $url"
        fetch_url "$url" "$raw" && ok=0 || ok=1
    fi

    if [ "$ok" -eq 0 ] && require_json_type "$raw" "$want" "$key"; then
        cp -- "$raw" "$dest"
        cache_store "$cache_name" "$dest"
        FETCH_SOURCE="$([ "$OFFLINE" = "1" ] && echo fixture || echo network)"
        FETCH_AGE=0
        record_diagnostic "$key" "$url" "$FETCH_SOURCE" 0 "$(jq -r 'length' "$dest")" "ok"
        return 0
    fi

    # 3. stale cache fallback
    if [ "$allow_stale" = "1" ] && [ -n "$cfile" ] && [ -f "$cfile" ]; then
        local age
        age="$(cache_age "$cfile")"
        if [ "$age" -le "$STALE_MAX_AGE" ] && require_json_type "$cfile" "$want" "stale:$key"; then
            cp -- "$cfile" "$dest"
            FETCH_SOURCE="stale-cache"
            FETCH_AGE="$age"
            add_warning "STALE DATA: '$key' could not be refreshed; using cached copy from $((age / 60)) minutes ago."
            record_diagnostic "$key" "$url" "stale-cache" "$age" "$(jq -r 'length' "$dest")" "stale fallback"
            return 0
        fi
    fi

    record_diagnostic "$key" "$url" "unavailable" null null "fetch or validation failed"
    log_debug "Could not obtain valid $want for '$key'"
    return 1
}

# --------------------------------------------------------------------------
# Stage loaders
# --------------------------------------------------------------------------
load_state() {
    if [ -n "$SEASON" ] && [ -n "$WEEK" ]; then
        log_debug "Season and week supplied; /state/nfl still used for provenance"
    fi
    if fetch_json state "$API/state/nfl" object - 0 0; then
        STATE_SEASON="$(jq -r '.season // empty' "$TMP_DIR/state.json")"
        STATE_WEEK="$(jq -r '.week // empty' "$TMP_DIR/state.json")"
        local state_season_type
        state_season_type="$(jq -r '.season_type // empty' "$TMP_DIR/state.json")"
        if [ -n "$state_season_type" ] && [ "$state_season_type" != "$SEASON_TYPE" ]; then
            add_warning "NFL state reports season type '$state_season_type' but '$SEASON_TYPE' was requested."
        fi
    else
        STATE_SEASON=""
        STATE_WEEK=""
        if [ -z "$SEASON" ] || [ -z "$WEEK" ]; then
            die "$EX_DATA" "Could not load /state/nfl and no --season/--week supplied. Rerun with --season YYYY --week N."
        fi
        add_warning "Could not load NFL state; using supplied season/week."
    fi
    [ -n "$SEASON" ] || SEASON="$STATE_SEASON"
    [ -n "$WEEK" ] || WEEK="$STATE_WEEK"
    [ -n "$SEASON" ] || die "$EX_DATA" "Season unavailable from /state/nfl; pass --season YYYY."
    [ -n "$WEEK" ] || die "$EX_DATA" "Week unavailable from /state/nfl; pass --week N."
    if ! is_uint "$WEEK" || [ "$WEEK" -lt 1 ] || [ "$WEEK" -gt 18 ]; then
        die "$EX_DATA" "Resolved week '$WEEK' is out of range 1-18; pass --week N."
    fi
    log_info "Season $SEASON, week $WEEK, season type $SEASON_TYPE"
}

load_league() {
    fetch_json league "$API/league/$LEAGUE_ID" object - 0 0 \
        || die "$EX_DATA" "League $LEAGUE_ID could not be loaded or is not a JSON object. Check the league id."
    local positions
    positions="$(jq -r '.roster_positions // [] | length' "$TMP_DIR/league.json")"
    [ "$positions" -gt 0 ] \
        || die "$EX_DATA" "League $LEAGUE_ID has no roster_positions; cannot build a lineup."
    if [ "$(jq -r '.scoring_settings // empty | length' "$TMP_DIR/league.json")" = "" ]; then
        add_warning "League has no scoring_settings; projections will fall back to provider aggregate points."
    fi
    fetch_json rosters "$API/league/$LEAGUE_ID/rosters" array - 0 0 \
        || die "$EX_DATA" "League rosters unavailable or empty for league $LEAGUE_ID."
    fetch_json users "$API/league/$LEAGUE_ID/users" array - 0 0 \
        || die "$EX_DATA" "League users unavailable or empty for league $LEAGUE_ID."
    if ! fetch_json matchups "$API/league/$LEAGUE_ID/matchups/$WEEK" array - 0 0; then
        add_warning "Week $WEEK matchups unavailable; matchup context omitted."
        printf '[]\n' > "$TMP_DIR/matchups.json"
    fi
}

resolve_user_and_roster() {
    if ! fetch_json user "$API/user/$USERNAME" object - 0 0; then
        die "$EX_DATA" "Sleeper user '$USERNAME' could not be resolved. Check --username."
    fi
    USER_ID="$(jq -r '.user_id // empty' "$TMP_DIR/user.json")"
    [ -n "$USER_ID" ] || die "$EX_DATA" "Sleeper user '$USERNAME' has no user_id in the API response."
    MY_ROSTER_ID="$(jq -r --arg uid "$USER_ID" 'map(select(.owner_id == $uid)) | .[0].roster_id // empty' "$TMP_DIR/rosters.json")"
    if [ -z "$MY_ROSTER_ID" ]; then
        MY_ROSTER_ID="$(jq -r --arg uid "$USER_ID" \
            'map(select((.co_owners // []) | index($uid))) | .[0].roster_id // empty' "$TMP_DIR/rosters.json")"
    fi
    [ -n "$MY_ROSTER_ID" ] \
        || die "$EX_DATA" "User '$USERNAME' (id $USER_ID) does not own a roster in league $LEAGUE_ID."
    log_info "User $USERNAME -> user_id $USER_ID, roster_id $MY_ROSTER_ID"
}

load_players() {
    if ! fetch_json players "$API/players/nfl" object "players_nfl" "$PLAYERS_TTL" 1; then
        die "$EX_DATA" "Player database unavailable (network and cache). Retry later or run with --fixtures."
    fi
    PLAYERS_SOURCE="$FETCH_SOURCE"
    PLAYERS_AGE="$FETCH_AGE"
    # Slim the player database down to the fields the analysis needs.
    jq '[ to_entries[]
          | {key: .key,
             value: {
               player_id: (.value.player_id // .key),
               full_name: (.value.full_name // ((.value.first_name // "") + " " + (.value.last_name // "")) | gsub("^ +| +$"; "")),
               position: .value.position,
               fantasy_positions: (.value.fantasy_positions // []),
               team: .value.team,
               status: .value.status,
               injury_status: .value.injury_status,
               injury_notes: .value.injury_notes,
               practice_participation: .value.practice_participation,
               active: .value.active,
               years_exp: .value.years_exp,
               depth_chart_position: .value.depth_chart_position,
               depth_chart_order: .value.depth_chart_order,
               news_updated: .value.news_updated
             }} ] | from_entries' \
        "$TMP_DIR/players.json" > "$TMP_DIR/players_slim.json"
    log_info "Player database: $(jq -r 'length' "$TMP_DIR/players_slim.json") players (source $PLAYERS_SOURCE)"
}

projection_url() {
    printf '%s/%s/%s?season_type=%s&order_by=pts_ppr' \
        "$PROJECTIONS_BASE" "$SEASON" "$WEEK" "$SEASON_TYPE"
}

load_projections() {
    # The projection feed is not part of Sleeper's documented read-only API and
    # is treated as an unstable dependency: single interface, cached, validated.
    PROJECTIONS_URL="$(projection_url)"
    local cache_name="projections_${SEASON}_${SEASON_TYPE}_${WEEK}"
    if fetch_json projections "$PROJECTIONS_URL" array "$cache_name" "$PROJECTIONS_TTL" 1; then
        PROJECTIONS_SOURCE="$FETCH_SOURCE"
        PROJECTIONS_AGE="$FETCH_AGE"
    else
        die "$EX_DATA" "No valid projections for season $SEASON week $WEEK (source: $PROJECTIONS_URL). Lineup and waiver analysis need projections; refusing to rank every player at zero."
    fi
    local count
    count="$(jq -r 'length' "$TMP_DIR/projections.json")"
    if [ "$count" -lt 50 ]; then
        add_warning "Projection feed returned only $count records; results may be incomplete."
    fi
    if [ "$(jq -r '[.[] | select(has("player_id") and (.stats | type == "object"))] | length' "$TMP_DIR/projections.json")" = "0" ]; then
        die "$EX_DATA" "Projection feed schema changed: no records with 'player_id' and object 'stats' (source: $PROJECTIONS_URL)."
    fi
    PROJECTIONS_FETCHED_AT="$(now_iso)"
    log_info "Projections: $count records (source $PROJECTIONS_SOURCE)"
}

load_activity() {
    TRENDING_AVAILABLE=false
    TRANSACTIONS_AVAILABLE=false
    if fetch_json trending_add "$API/players/nfl/trending/add?lookback_hours=24&limit=100" array "trending_add" "$TRENDING_TTL" 1; then
        TRENDING_AVAILABLE=true
    else
        printf '[]\n' > "$TMP_DIR/trending_add.json"
        add_warning "Trending add data unavailable; the add-trend component is omitted from waiver scoring."
    fi
    if fetch_json transactions "$API/league/$LEAGUE_ID/transactions/$WEEK" array - 0 0; then
        TRANSACTIONS_AVAILABLE=true
    else
        printf '[]\n' > "$TMP_DIR/transactions.json"
        log_debug "No transactions for week $WEEK"
    fi
}

# --------------------------------------------------------------------------
# Analysis (pure JSON in, JSON out)
# --------------------------------------------------------------------------
build_bundle() {
    local warnings_json
    if [ "${#WARNINGS[@]}" -gt 0 ]; then
        warnings_json="$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s .)"
    else
        warnings_json='[]'
    fi
    jq -n \
        --slurpfile league "$TMP_DIR/league.json" \
        --slurpfile rosters "$TMP_DIR/rosters.json" \
        --slurpfile users "$TMP_DIR/users.json" \
        --slurpfile matchups "$TMP_DIR/matchups.json" \
        --slurpfile players "$TMP_DIR/players_slim.json" \
        --slurpfile projections "$TMP_DIR/projections.json" \
        --slurpfile trending "$TMP_DIR/trending_add.json" \
        --slurpfile transactions "$TMP_DIR/transactions.json" \
        --slurpfile diagnostics "$DIAGNOSTICS_FILE" \
        --argjson warnings "$warnings_json" \
        --arg tool_version "$TOOL_VERSION" \
        --arg generated_at "$(now_iso)" \
        --arg league_id "$LEAGUE_ID" \
        --arg username "$USERNAME" \
        --arg user_id "$USER_ID" \
        --arg season "$SEASON" \
        --arg season_type "$SEASON_TYPE" \
        --argjson week "$WEEK" \
        --argjson my_roster_id "$MY_ROSTER_ID" \
        --argjson top_n "$TOP_N" \
        --argjson threshold "$CHURN_THRESHOLD" \
        --argjson fairness "$FAIRNESS" \
        --argjson skip_waivers "$([ "$SKIP_WAIVERS" = "1" ] && echo true || echo false)" \
        --argjson skip_trades "$([ "$SKIP_TRADES" = "1" ] && echo true || echo false)" \
        --argjson offline "$([ "$OFFLINE" = "1" ] && echo true || echo false)" \
        --arg projections_url "$PROJECTIONS_URL" \
        --arg projections_source "$PROJECTIONS_SOURCE" \
        --argjson projections_age "$PROJECTIONS_AGE" \
        --arg projections_fetched_at "$PROJECTIONS_FETCHED_AT" \
        --arg players_source "$PLAYERS_SOURCE" \
        --argjson players_age "$PLAYERS_AGE" \
        --argjson trending_available "$TRENDING_AVAILABLE" \
        --argjson transactions_available "$TRANSACTIONS_AVAILABLE" \
        '{
           config: {
             tool_version: $tool_version, generated_at: $generated_at,
             league_id: $league_id, username: $username, user_id: $user_id,
             season: $season, season_type: $season_type, week: $week,
             my_roster_id: $my_roster_id, top_n: $top_n,
             churn_threshold: $threshold, fairness: $fairness,
             skip_waivers: $skip_waivers, skip_trades: $skip_trades, offline: $offline
           },
           provenance: {
             projections: {url: $projections_url, source: $projections_source,
                           cache_age_seconds: $projections_age, fetched_at: $projections_fetched_at},
             players: {source: $players_source, cache_age_seconds: $players_age},
             trending_available: $trending_available,
             transactions_available: $transactions_available
           },
           warnings: $warnings,
           league: $league[0], rosters: $rosters[0], users: $users[0],
           matchups: $matchups[0], players: $players[0], projections: $projections[0],
           trending_add: $trending[0], transactions: $transactions[0],
           diagnostics: $diagnostics[0]
         }' > "$TMP_DIR/bundle.json"
    log_debug "Analysis bundle: $(wc -c < "$TMP_DIR/bundle.json" | tr -d ' ') bytes"
}

run_analysis() {
    if ! python3 "$ANALYSIS_PY" < "$TMP_DIR/bundle.json" > "$TMP_DIR/report.json" 2>"$TMP_DIR/analysis.err"; then
        log_error "Analysis failed: $(tail -c 1000 -- "$TMP_DIR/analysis.err" | redact)"
        exit "$EX_DATA"
    fi
    if [ -s "$TMP_DIR/analysis.err" ]; then
        while IFS= read -r line; do
            log_debug "analysis: $line"
        done < "$TMP_DIR/analysis.err"
    fi
    jq -e 'type == "object" and has("lineup")' "$TMP_DIR/report.json" >/dev/null \
        || die "$EX_DATA" "Analysis produced an invalid report."
}

# --------------------------------------------------------------------------
# Renderers (report JSON -> text / markdown)
# --------------------------------------------------------------------------
render_text() {
    jq -r '
      def n(x): if x == null then "n/a" else (x * 10 | round / 10 | tostring) end;
      def pad(s; w): (s | tostring) as $s | $s + (" " * (if w > ($s|length) then w - ($s|length) else 0 end));
      def line: "-" * 72;
      def player(p): if p == null then "(empty)"
                     else (p.name // "unknown") + " " + "(" + (p.position // "?") + "/" + (p.team // "FA") + ")"
                     end;
      [
        "=" * 72,
        "FANTASY MANAGER - " + (.metadata.league_name // "league") + " - Week " + (.metadata.week|tostring) + " (" + .metadata.season + " " + .metadata.season_type + ")",
        "Manager: " + .metadata.username + "   Team: " + (.metadata.team_name // "n/a"),
        "Generated: " + .metadata.generated_at + "   Tool: fantasy_manager " + .metadata.tool_version,
        "=" * 72,
        "",
        "SCORING: " + .metadata.scoring.mode + " (source: " + .metadata.scoring.source + ")",
        "PROJECTIONS: " + .metadata.projections.source + " | " + .metadata.projections.url,
        "  fetched " + (.metadata.projections.fetched_at // "n/a")
          + " | cache age " + (if .metadata.projections.cache_age_seconds == null then "n/a" else ((.metadata.projections.cache_age_seconds/60|floor|tostring) + "m") end)
          + " | records " + (.metadata.projections.record_count|tostring)
          + (if .metadata.projections.stale then "  *** STALE ***" else "" end),
        ""
      ]
      + (if (.warnings | length) > 0
         then ["WARNINGS", line] + (.warnings | map("  ! " + .)) + [""]
         else [] end)
      + ["LINEUP - week " + (.metadata.week|tostring), line,
         "  Current projected:   " + n(.lineup.current_points),
         "  Optimal projected:   " + n(.lineup.optimal_points),
         "  Potential gain:      " + n(.lineup.gain),
         ""]
      + ["  " + pad("SLOT"; 12) + pad("CURRENT"; 26) + pad("RECOMMENDED"; 26) + pad("ACTION"; 12) + "GAIN"]
      + (.lineup.slots | map(
            "  " + pad(.slot; 12) + pad(player(.current); 26) + pad(player(.recommended); 26)
                 + pad(.action; 12) + n(.gain)
                 + (if .below_threshold then "  (optional)" else "" end)))
      + [""]
      + (if (.lineup.risk | length) > 0
         then ["  RISK / AVAILABILITY"]
              + (.lineup.risk | map("    - " + .name + " (" + (.position // "?") + "): "
                  + ([.status, .injury_status, .practice_participation] | map(select(. != null)) | join(", "))
                  + (if .note == null then "" else " - " + .note end)))
              + [""]
         else [] end)
      + (if .matchup == null then ["MATCHUP: unavailable", ""]
         else ["MATCHUP", line,
               "  " + (.matchup.my_team // "me") + "  vs  " + (.matchup.opponent_team // "unknown"),
               "  Projected (current lineups): " + n(.matchup.my_projected) + "  vs  " + n(.matchup.opponent_projected),
               "  Differential: " + n(.matchup.differential),
               "  Live/final points: " + n(.matchup.my_points) + "  vs  " + n(.matchup.opponent_points),
               "  Note: " + .matchup.note, ""] end)
      + (if .waivers == null then ["WAIVERS: skipped", ""]
         else ["WAIVERS", line,
               "  Waiver type: " + .waivers.waiver.type
                 + (if .waivers.waiver.budget == null then ""
                    else "  budget " + (.waivers.waiver.budget|tostring) + ", remaining " + (.waivers.waiver.remaining|tostring) end),
               "  Weights: " + (.waivers.weights_used | to_entries | map(.key + " " + ((.value*100)|round|tostring) + "%") | join(", ")),
               "  Omitted components: " + (if (.waivers.omitted_components|length) == 0 then "none" else (.waivers.omitted_components | join(", ")) end),
               ""]
              + ( [ {t:"PRIORITY CLAIMS", g:.waivers.groups.priority},
                    {t:"BENCH UPGRADES / STASHES", g:.waivers.groups.bench_upgrades},
                    {t:"STREAMERS", g:.waivers.groups.streamers},
                    {t:"AVOID", g:.waivers.groups.avoid} ]
                  | map( ["  " + .t]
                         + (if (.g|length) == 0 then ["    (none)"]
                            else (.g | map("    " + pad(.name + " (" + (.position // "?") + "/" + (.team // "FA") + ")"; 30)
                                   + "proj " + pad(n(.projection); 7)
                                   + "net " + pad(n(.net_gain); 7)
                                   + "score " + pad(n(.score); 7)
                                   + (if .suggested_bid == null then "" else "bid $" + (.suggested_bid|tostring) + " (" + (.suggested_bid_pct|tostring) + "% est) " end)
                                   + (if .drop_candidate == null then "" else "drop " + .drop_candidate.name end)
                                   + (if (.notes|length) > 0 then " [" + (.notes|join("; ")) + "]" else "" end)))
                            end)
                         + [""] )
                  | add )
         end)
      + (if .trades == null then ["TRADES: skipped", ""]
         else ["TRADES", line,
               "  My needs:   " + (if (.trades.my_needs|length) == 0 then "none identified" else (.trades.my_needs | map(.position + " (" + n(.starter_points) + " vs league " + n(.league_average) + ")") | join(", ")) end),
               "  My surplus: " + (if (.trades.my_surplus|length) == 0 then "none identified" else (.trades.my_surplus | map(.name + " (" + (.position // "?") + ", cost " + n(.lineup_cost) + ")") | join(", ")) end),
               ""]
              + (if (.trades.partners|length) == 0 then ["  No balanced packages found within the fairness tolerance.", ""]
                 else (.trades.partners | map(
                        ["  " + (.team // "roster " + (.roster_id|tostring))
                           + "  needs: " + (if (.needs|length)==0 then "none" else (.needs|map(.position)|join(", ")) end),
                         "    depth before: " + (.depth_before | to_entries | map(.key + " " + n(.value)) | join(", "))]
                        + (if (.packages|length) == 0 then ["    (no balanced package)"]
                           else (.packages | map(
                              "    GIVE " + (.give | map(.name + " (" + (.position // "?") + ")") | join(" + "))
                              + "  GET " + (.get | map(.name + " (" + (.position // "?") + ")") | join(" + "))
                              + "  | my gain " + n(.my_gain) + ", their gain " + n(.their_gain)
                              + ", fairness gap " + n(.fairness_gap)))
                           end)
                        + [""]) | add)
                 end)
         end)
      + ["DIAGNOSTICS", line]
      + (.diagnostics.fetches | map("  " + pad(.key; 16) + pad(.source; 14)
            + (if .cache_age_seconds == null then "" else "age " + ((.cache_age_seconds/60|floor)|tostring) + "m  " end)
            + (if .records == null then "" else (.records|tostring) + " records  " end)
            + .note))
      + ["",
         "This tool is read-only: it cannot submit lineups, waiver claims or trades.",
         "Projections are advisory; no correlation or game-script modelling is performed."]
      | .[]
    ' "$1"
}

render_markdown() {
    jq -r '
      def n(x): if x == null then "n/a" else (x * 10 | round / 10 | tostring) end;
      def player(p): if p == null then "_(empty)_" else (p.name // "unknown") + " (" + (p.position // "?") + "/" + (p.team // "FA") + ")" end;
      [
        "# Fantasy Manager - " + (.metadata.league_name // "league") + " - Week " + (.metadata.week|tostring),
        "",
        "- Season: " + .metadata.season + " (" + .metadata.season_type + ")",
        "- Manager: " + .metadata.username + " - Team: " + (.metadata.team_name // "n/a"),
        "- Generated: " + .metadata.generated_at + " by fantasy_manager " + .metadata.tool_version,
        "- Scoring: " + .metadata.scoring.mode + " (source: " + .metadata.scoring.source + ")",
        "- Projections: " + .metadata.projections.source + " - `" + .metadata.projections.url + "` - "
          + (.metadata.projections.record_count|tostring) + " records"
          + (if .metadata.projections.stale then " - **STALE**" else "" end),
        ""
      ]
      + (if (.metadata.scoring.unsupported_keys|length) > 0
         then ["> Unsupported scoring keys (no matching projection stat): "
               + (.metadata.scoring.unsupported_keys | join(", ")), ""] else [] end)
      + (if (.warnings|length) > 0 then ["## Warnings", ""] + (.warnings | map("- " + .)) + [""] else [] end)
      + ["## Lineup", "",
         "| Metric | Points |", "| --- | ---: |",
         "| Current | " + n(.lineup.current_points) + " |",
         "| Optimal | " + n(.lineup.optimal_points) + " |",
         "| Gain | " + n(.lineup.gain) + " |",
         "",
         "| Slot | Current | Recommended | Action | Gain |",
         "| --- | --- | --- | --- | ---: |"]
      + (.lineup.slots | map("| " + .slot + " | " + player(.current) + " | " + player(.recommended)
            + " | " + .action + (if .below_threshold then " (optional)" else "" end) + " | " + n(.gain) + " |"))
      + [""]
      + (if (.lineup.risk|length) > 0
         then ["### Availability risk", ""]
              + (.lineup.risk | map("- **" + .name + "** (" + (.position // "?") + "): "
                  + ([.status, .injury_status, .practice_participation] | map(select(. != null)) | join(", "))))
              + [""]
         else [] end)
      + (if .matchup == null then ["## Matchup", "", "Matchup data unavailable.", ""]
         else ["## Matchup", "",
               "| Team | Projected (current lineup) | Live points |",
               "| --- | ---: | ---: |",
               "| " + (.matchup.my_team // "me") + " | " + n(.matchup.my_projected) + " | " + n(.matchup.my_points) + " |",
               "| " + (.matchup.opponent_team // "unknown") + " | " + n(.matchup.opponent_projected) + " | " + n(.matchup.opponent_points) + " |",
               "", "Differential: " + n(.matchup.differential), "", "> " + .matchup.note, ""] end)
      + (if .waivers == null then []
         else ["## Waivers", "",
               "- Waiver type: " + .waivers.waiver.type
                 + (if .waivers.waiver.budget == null then "" else " (budget " + (.waivers.waiver.budget|tostring) + ", remaining " + (.waivers.waiver.remaining|tostring) + ")" end),
               "- Weights: " + (.waivers.weights_used | to_entries | map(.key + " " + ((.value*100)|round|tostring) + "%") | join(", ")),
               "- Omitted components: " + (if (.waivers.omitted_components|length) == 0 then "none" else (.waivers.omitted_components|join(", ")) end),
               ""]
              + ( [ {t:"Priority claims", g:.waivers.groups.priority},
                    {t:"Bench upgrades / stashes", g:.waivers.groups.bench_upgrades},
                    {t:"Streamers", g:.waivers.groups.streamers},
                    {t:"Avoid", g:.waivers.groups.avoid} ]
                  | map(["### " + .t, "",
                         "| Player | Pos | Team | Proj | Net gain | Score | Bid (est) | Drop |",
                         "| --- | --- | --- | ---: | ---: | ---: | --- | --- |"]
                        + (if (.g|length) == 0 then ["| _(none)_ | | | | | | | |"]
                           else (.g | map("| " + .name + " | " + (.position // "?") + " | " + (.team // "FA")
                                 + " | " + n(.projection) + " | " + n(.net_gain) + " | " + n(.score)
                                 + " | " + (if .suggested_bid == null then "n/a" else "$" + (.suggested_bid|tostring) + " (" + (.suggested_bid_pct|tostring) + "%)" end)
                                 + " | " + (if .drop_candidate == null then "n/a" else .drop_candidate.name end) + " |"))
                           end)
                        + [""])
                  | add )
         end)
      + (if .trades == null then []
         else ["## Trades", "",
               "- My needs: " + (if (.trades.my_needs|length)==0 then "none identified" else (.trades.my_needs|map(.position)|join(", ")) end),
               "- My surplus: " + (if (.trades.my_surplus|length)==0 then "none identified" else (.trades.my_surplus|map(.name)|join(", ")) end),
               ""]
              + (if (.trades.partners|length) == 0 then ["No balanced packages found within the fairness tolerance.", ""]
                 else (.trades.partners | map(
                     ["### " + (.team // ("roster " + (.roster_id|tostring))), "",
                      "- Needs: " + (if (.needs|length)==0 then "none" else (.needs|map(.position)|join(", ")) end), ""]
                     + (if (.packages|length)==0 then ["_No balanced package._", ""]
                        else ["| Give | Get | My gain | Their gain | Fairness gap |", "| --- | --- | ---: | ---: | ---: |"]
                             + (.packages | map("| " + (.give|map(.name)|join(" + ")) + " | " + (.get|map(.name)|join(" + "))
                                 + " | " + n(.my_gain) + " | " + n(.their_gain) + " | " + n(.fairness_gap) + " |"))
                             + [""]
                        end)) | add)
                 end)
         end)
      + ["## Diagnostics", "", "| Source | Origin | Cache age | Records | Note |", "| --- | --- | --- | ---: | --- |"]
      + (.diagnostics.fetches | map("| " + .key + " | " + .source + " | "
            + (if .cache_age_seconds == null then "n/a" else ((.cache_age_seconds/60|floor)|tostring) + "m" end)
            + " | " + (if .records == null then "n/a" else (.records|tostring) end) + " | " + .note + " |"))
      + ["",
         "> Read-only tool: it cannot submit lineups, waiver claims or trades.",
         "> Projections are advisory and do not model correlation or game script."]
      | .[]
    ' "$1"
}

render_report() {
    local report="$TMP_DIR/report.json" rendered="$TMP_DIR/rendered.out"
    case "$FORMAT" in
        json)     jq -S . "$report" > "$rendered" ;;
        text)     render_text "$report" > "$rendered" ;;
        markdown) render_markdown "$report" > "$rendered" ;;
    esac
    if [ "$OUTPUT" = "-" ]; then
        cat -- "$rendered"
    else
        mkdir -p "$(dirname -- "$OUTPUT")" 2>/dev/null || true
        cp -- "$rendered" "$OUTPUT"
        log_info "Report written to $OUTPUT"
    fi
}

# --------------------------------------------------------------------------
main() {
    parse_args "$@"
    load_configuration
    check_dependencies
    init_runtime
    load_state
    load_league
    resolve_user_and_roster
    load_players
    load_projections
    load_activity
    build_bundle
    run_analysis
    render_report
}

main "$@"
