#!/usr/bin/env python3
"""fantasy_manager - Sleeper weekly decision support (lineup / waivers / trades).

The whole application except analysis: command line, configuration, fetching,
caching, validation, the run pipeline and text/Markdown/JSON rendering. Both
front ends are thin wrappers around it: fantasy_manager.sh (macOS/Linux) and
FantasyManager.ps1 (Windows; its window runs this in the background).

Read-only: this tool NEVER submits lineups, waiver claims or trades.
Standard library only (Python 3.8+).
"""

from __future__ import annotations

import datetime
import json
import math
import os
import re
import sys
import time
import traceback
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_analysis  # noqa: E402
import fm_history  # noqa: E402

TOOL_NAME = "fantasy_manager"
TOOL_VERSION = "2.8.0"

# --------------------------------------------------------------------------
# Defaults (run with no parameters)
# --------------------------------------------------------------------------
DEFAULT_LEAGUE_ID = "1400680781302525952"
DEFAULT_USERNAME = "MaTrasaMaae"
DEFAULT_API = "https://api.sleeper.app/v1"
DEFAULT_PROJECTIONS_BASE = "https://api.sleeper.app/projections/nfl"
# Unofficial game schedule (status per game); optional, used for locks and week rollover.
DEFAULT_SCHEDULE_BASE = "https://api.sleeper.com/schedule/nfl"
# Unofficial weekly stats (actual results); optional, adds free agents and usage to history.
DEFAULT_STATS_BASE = "https://api.sleeper.app/stats/nfl"
DEFAULT_SEASON_TYPE = "regular"
DEFAULT_TOP_N = "10"
DEFAULT_HORIZON = "3"             # future weeks valued alongside this one
DEFAULT_FORMAT = "text"
DEFAULT_OUTPUT = "-"
DEFAULT_CHURN_THRESHOLD = "0.5"
DEFAULT_FAIRNESS = "0.10"
DEFAULT_LOG_LEVEL = "INFO"
DEFAULT_PLAYERS_TTL = "86400"     # 24h
DEFAULT_PROJECTIONS_TTL = "21600"  # 6h
DEFAULT_TRENDING_TTL = "21600"    # 6h
DEFAULT_SCHEDULE_TTL = "300"      # 5m: game status changes on game days
DEFAULT_STALE_MAX_AGE = "604800"  # 7 days: oldest cache still usable as a fallback

EX_OK, EX_USAGE, EX_DEPENDENCY, EX_DATA = 0, 2, 3, 4


def default_dir(kind: str) -> str:
    """Cache / config folder: %LOCALAPPDATA% / %APPDATA% on Windows, XDG elsewhere."""
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA" if kind == "cache" else "APPDATA") or os.path.expanduser("~")
        return os.path.join(base, TOOL_NAME)
    if kind == "cache":
        base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, TOOL_NAME)


DEFAULT_CACHE_DIR = default_dir("cache")
DEFAULT_CONFIG_FILE = os.path.join(default_dir("config"), "config.env")

USAGE = """fantasy_manager.sh - Sleeper weekly decision support (lineup / waivers / trades)

Usage: fantasy_manager.sh [options]

Data options:
  -l, --league-id ID       Sleeper league id (default: 1400680781302525952)
  -u, --username NAME      Sleeper username (default: MaTrasaMaae)
  -w, --week N             NFL week, 1-18 (default: current week from /state/nfl,
                           or the next week once every game of it is complete)
  -s, --season YYYY        Season (default: current season from /state/nfl)
      --season-type TYPE   regular|pre|post (default: regular)
  -n, --top N              Number of ranked rows per section, 1-50 (default: 10)

Analysis options:
      --threshold X        Suppress lineup churn below X projected points (default: 0.5)
      --fairness X         Trade fairness tolerance as a fraction (default: 0.10)
      --horizon N          Future weeks valued for waivers, drops and trades, 0-6
                           (default: 3; 0 = this week only)
      --trade TEXT         Grade trade(s) in your league: "Give A, Give B for Get C".
                           Any two teams; names or Sleeper ids; ";" between trades
      --value-trade TEXT   Grade any players for any players, no league or rosters
                           needed (e.g. a friend's offer): "A, B for C".
                           Add a team or position to disambiguate ("Josh Allen BUF")
      --scoring FMT        Scoring for --value-trade: ppr, half, std or league
                           (default: ppr)
      --teams N            League size for --value-trade replacement levels,
                           4-32 (default: 12)
      --locked LIST        Comma-separated player names or ids whose games have
                           started; they are never moved (added to auto-detection)
      --skip-waivers       Skip waiver analysis
      --skip-trades        Skip trade analysis
      --no-history         Don't record or report past weeks (projection accuracy,
                           recent form)
      --history-db PATH    History database (default: history.sqlite in the cache
                           directory; in memory with --no-cache)

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
"""


class Exit(Exception):
    def __init__(self, code: int):
        super().__init__(code)
        self.code = code


# --------------------------------------------------------------------------
# Logging (diagnostics on stderr, clean report on stdout)
# --------------------------------------------------------------------------
LEVELS = {"ERROR": 0, "WARN": 1, "INFO": 2, "DEBUG": 3, "QUIET": 0}
REDACT_1 = re.compile(
    r"""(([Tt]oken|[Ss]ecret|[Aa]pi[_-]?[Kk]ey|[Aa]uthorization|[Pp]assword)["']?\s*[:=]\s*["']?)[^"'\s,}]+""")
REDACT_2 = re.compile(r"([?&](access_token|api_key|token|key)=)[^&\s]+")


def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def redact(text: str) -> str:
    text = REDACT_1.sub(r"\1***REDACTED***", text)
    return REDACT_2.sub(r"\1***REDACTED***", text)


class Logger:
    def __init__(self) -> None:
        self.level = DEFAULT_LOG_LEVEL
        self.file: Optional[str] = None

    def write_err(self, text: str) -> None:
        try:
            sys.stderr.write(text)
        except UnicodeEncodeError:
            sys.stderr.write(text.encode("ascii", "replace").decode("ascii"))
        sys.stderr.flush()
        if self.file:
            try:
                with open(self.file, "a", encoding="utf-8") as fh:
                    fh.write(text)
            except OSError:
                pass

    def log(self, level: str, message: str) -> None:
        if LEVELS.get(level, 2) <= LEVELS.get(self.level, 2):
            self.write_err(redact("%s [%s] %s" % (now_iso(), level, message)) + "\n")

    def error(self, m: str) -> None: self.log("ERROR", m)
    def warn(self, m: str) -> None: self.log("WARN", m)
    def info(self, m: str) -> None: self.log("INFO", m)
    def debug(self, m: str) -> None: self.log("DEBUG", m)


LOG = Logger()


def die(code: int, message: str) -> None:
    LOG.error(message)
    raise Exit(code)


# --------------------------------------------------------------------------
# jq-compatible formatting helpers (keep reports identical across versions)
# --------------------------------------------------------------------------
def c_round(v: float) -> float:
    """C/jq round(): halves away from zero."""
    a = abs(v)
    r = math.floor(a)
    if a - r >= 0.5:
        r += 1
    return math.copysign(r, v)


def num(v: Any) -> str:
    """A computed number as jq prints it (whole numbers without '.0')."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v.is_integer() and abs(v) < 1e17:
            return "-0" if v == 0 and math.copysign(1.0, v) < 0 else str(int(v))
        return repr(v)
    return str(v)


def ts(v: Any) -> str:
    """jq tostring of a value read from JSON (numbers keep their literal form)."""
    if v is None:
        return "null"
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return "true" if v else "false"
    return json.dumps(v, ensure_ascii=False)


def n1(v: Any) -> str:
    """jq: if x == null then "n/a" else (x * 10 | round / 10 | tostring)."""
    if v is None:
        return "n/a"
    return num(c_round(v * 10) / 10)


def alt(a: Any, b: Any) -> Any:
    """jq a // b: b when a is null or false."""
    return b if a is None or a is False else a


def s(v: Any) -> str:
    """String concatenation operand (jq treats null as empty)."""
    return "" if v is None else v


def pad(v: Any, w: int) -> str:
    text = ts(v)
    return text + " " * (w - len(text) if w > len(text) else 1)


def truthy(v: Any) -> bool:
    return v is not None and v is not False


# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------
VALUE_OPTIONS = {
    "-l": "league_id", "--league-id": "league_id", "-u": "username", "--username": "username",
    "-w": "week", "--week": "week", "-s": "season", "--season": "season",
    "--season-type": "season_type", "-n": "top_n", "--top": "top_n",
    "--threshold": "threshold", "--fairness": "fairness", "--locked": "locked",
    "--trade": "trade", "--value-trade": "value_trade", "--scoring": "scoring",
    "--teams": "teams", "--horizon": "horizon", "-f": "format", "--format": "format",
    "-o": "output", "--output": "output", "--log-file": "log_file",
    "--cache-dir": "cache_dir", "--cache-ttl": "projections_ttl",
    "--fixtures": "fixtures", "--config": "config_file", "--history-db": "history_db",
}
FLAG_OPTIONS = {
    "--skip-waivers": ("skip_waivers", "1"), "--skip-trades": ("skip_trades", "1"),
    "-q": ("log_level", "QUIET"), "--quiet": ("log_level", "QUIET"),
    "-v": ("log_level", "INFO"), "--verbose": ("log_level", "INFO"),
    "--debug": ("log_level", "DEBUG"), "--no-cache": ("no_cache", "1"),
    "--refresh": ("refresh", "1"), "--offline": ("offline", "1"),
    # Hidden: print the effective configuration as JSON (used by the Windows window).
    "--print-config": ("print_config", "1"),
    "--no-history": ("history", "0"),
}


def usage_error(message: str) -> None:
    LOG.write_err(USAGE)
    die(EX_USAGE, message)


def parse_args(argv: List[str]) -> Dict[str, str]:
    cli: Dict[str, str] = {}

    def set_cli(key: str, value: str) -> None:
        if key in cli:
            LOG.debug("Duplicate option '%s': '%s' -> '%s' (last value wins)" % (key, cli[key], value))
        cli[key] = value

    i = 0
    while i < len(argv):
        arg = argv[i]
        remaining = len(argv) - i
        if arg in VALUE_OPTIONS:
            if remaining < 2:
                usage_error("Option '%s' requires a value." % arg)
            set_cli(VALUE_OPTIONS[arg], argv[i + 1])
            i += 2
        elif arg in FLAG_OPTIONS:
            key, value = FLAG_OPTIONS[arg]
            set_cli(key, value)
            i += 1
        elif arg in ("-h", "--help"):
            write_stdout(USAGE)
            raise Exit(EX_OK)
        elif arg in ("-V", "--version"):
            write_stdout("%s %s\n" % (TOOL_NAME, TOOL_VERSION))
            raise Exit(EX_OK)
        elif arg == "--":
            i += 1
            break
        elif arg.startswith("-"):
            usage_error("Unknown option '%s'." % arg)
        else:
            usage_error("Unexpected argument '%s'." % arg)
    if i < len(argv):
        usage_error("Unexpected argument '%s'." % argv[i])
    return cli


# --------------------------------------------------------------------------
# Configuration: CLI > environment (FM_*) > config file > defaults
# --------------------------------------------------------------------------
def read_text_any(path: str) -> str:
    """UTF-8 (with or without BOM) or UTF-16 text, as Notepad / PowerShell write it."""
    with open(path, "rb") as fh:
        data = fh.read()
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        return data.decode("utf-16", errors="replace")
    return data.decode("utf-8-sig", errors="replace")


def load_config_file(path: str) -> Dict[str, str]:
    values: Dict[str, str] = {}
    if not path or not os.path.isfile(path):
        LOG.debug("No config file at %s" % path)
        return values
    text = read_text_any(path)
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for line in lines:
        if line == "" or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = re.sub(r"\s", "", key).lower()
        if key.startswith("fm_"):
            key = key[3:]
        # Tolerate "key = value", trailing spaces and Windows line endings.
        if value.endswith("\r"):
            value = value[:-1]
        value = value.strip(" \t\n\r\x0b\x0c")
        if value.endswith('"'):
            value = value[:-1]
        if value.startswith('"'):
            value = value[1:]
        if value.endswith("'"):
            value = value[:-1]
        if value.startswith("'"):
            value = value[1:]
        values[key] = value
    LOG.debug("Loaded config file %s (%d keys)" % (path, len(values)))
    return values


def is_uint(v: str) -> bool:
    return re.fullmatch(r"[0-9]+", v or "") is not None


def is_number(v: str) -> bool:
    return re.fullmatch(r"-?[0-9]+(\.[0-9]+)?", v or "") is not None


def json_number(v: str) -> Any:
    return float(v) if "." in v else int(v)


class Config:
    pass


def load_configuration(cli: Dict[str, str]) -> Config:
    file_values: Dict[str, str] = {}

    def resolve(key: str, env: str, default: str) -> str:
        if key in cli:
            return cli[key]
        if os.environ.get(env):
            return os.environ[env]
        if key in file_values:
            return file_values[key]
        return default

    c = Config()
    c.config_file = resolve("config_file", "FM_CONFIG_FILE", DEFAULT_CONFIG_FILE)
    file_values.update(load_config_file(c.config_file))

    c.league_id = resolve("league_id", "FM_LEAGUE_ID", DEFAULT_LEAGUE_ID)
    c.username = resolve("username", "FM_USERNAME", DEFAULT_USERNAME)
    c.api = resolve("api", "FM_API", DEFAULT_API)
    c.projections_base = resolve("projections_base", "FM_PROJECTIONS_BASE", DEFAULT_PROJECTIONS_BASE)
    c.schedule_base = resolve("schedule_base", "FM_SCHEDULE_BASE", DEFAULT_SCHEDULE_BASE)
    c.schedule_ttl = resolve("schedule_ttl", "FM_SCHEDULE_TTL", DEFAULT_SCHEDULE_TTL)
    c.locked = resolve("locked", "FM_LOCKED", "")
    c.trade = resolve("trade", "FM_TRADE", "")
    c.value_trade = resolve("value_trade", "FM_VALUE_TRADE", "")
    c.scoring = resolve("scoring", "FM_SCORING", "ppr")
    c.teams = resolve("teams", "FM_TEAMS", "12")
    c.horizon = resolve("horizon", "FM_HORIZON", DEFAULT_HORIZON)
    c.week = resolve("week", "FM_WEEK", "")
    c.season = resolve("season", "FM_SEASON", "")
    c.season_type = resolve("season_type", "FM_SEASON_TYPE", DEFAULT_SEASON_TYPE)
    c.top_n = resolve("top_n", "FM_TOP_N", DEFAULT_TOP_N)
    c.threshold = resolve("threshold", "FM_THRESHOLD", DEFAULT_CHURN_THRESHOLD)
    c.fairness = resolve("fairness", "FM_FAIRNESS", DEFAULT_FAIRNESS)
    c.skip_waivers = resolve("skip_waivers", "FM_SKIP_WAIVERS", "0")
    c.skip_trades = resolve("skip_trades", "FM_SKIP_TRADES", "0")
    c.format = resolve("format", "FM_FORMAT", DEFAULT_FORMAT)
    c.output = resolve("output", "FM_OUTPUT", DEFAULT_OUTPUT)
    LOG.level = resolve("log_level", "FM_LOG_LEVEL", DEFAULT_LOG_LEVEL)
    c.log_file = resolve("log_file", "FM_LOG_FILE", "")
    c.cache_dir = resolve("cache_dir", "FM_CACHE_DIR", DEFAULT_CACHE_DIR)
    c.players_ttl = resolve("players_ttl", "FM_PLAYERS_TTL", DEFAULT_PLAYERS_TTL)
    c.projections_ttl = resolve("projections_ttl", "FM_PROJECTIONS_TTL", DEFAULT_PROJECTIONS_TTL)
    c.trending_ttl = resolve("trending_ttl", "FM_TRENDING_TTL", DEFAULT_TRENDING_TTL)
    c.stale_max_age = resolve("stale_max_age", "FM_STALE_MAX_AGE", DEFAULT_STALE_MAX_AGE)
    c.no_cache = resolve("no_cache", "FM_NO_CACHE", "0")
    c.refresh = resolve("refresh", "FM_REFRESH", "0")
    c.offline = resolve("offline", "FM_OFFLINE", "0")
    c.fixtures = resolve("fixtures", "FM_FIXTURES", "")
    c.print_config = cli.get("print_config") == "1"
    c.history = resolve("history", "FM_HISTORY", "1")
    c.history_db = resolve("history_db", "FM_HISTORY_DB", "")
    c.stats_base = resolve("stats_base", "FM_STATS_BASE", DEFAULT_STATS_BASE)

    # Offline fixture data must never land in (or be read from) the real
    # cache, or the next live run would serve synthetic players/projections.
    # An explicitly chosen cache directory is still honoured for testing.
    if c.offline == "1" and c.cache_dir == DEFAULT_CACHE_DIR:
        c.no_cache = "1"

    validate_config(c)

    LOG.debug("Effective configuration:")
    LOG.debug("  league_id=%s username=%s api=%s" % (c.league_id, c.username, c.api))
    LOG.debug("  projections_base=%s season=%s week=%s season_type=%s"
              % (c.projections_base, c.season or "auto", c.week or "auto", c.season_type))
    LOG.debug("  top_n=%s threshold=%s fairness=%s horizon=%s" % (c.top_n, c.threshold, c.fairness, c.horizon))
    LOG.debug("  format=%s output=%s log_level=%s log_file=%s" % (c.format, c.output, LOG.level, c.log_file or "none"))
    LOG.debug("  cache_dir=%s projections_ttl=%s no_cache=%s refresh=%s"
              % (c.cache_dir, c.projections_ttl, c.no_cache, c.refresh))
    LOG.debug("  offline=%s fixtures=%s config_file=%s" % (c.offline, c.fixtures or "none", c.config_file))
    LOG.debug("  skip_waivers=%s skip_trades=%s locked=%s" % (c.skip_waivers, c.skip_trades, c.locked or "none"))
    LOG.debug("  schedule_base=%s schedule_ttl=%s" % (c.schedule_base, c.schedule_ttl))
    LOG.debug("  history=%s history_db=%s stats_base=%s" % (c.history, c.history_db or "default", c.stats_base))
    return c


def validate_config(c: Config) -> None:
    if not is_uint(c.league_id):
        die(EX_USAGE, "League id must be a non-empty numeric string (got '%s')." % c.league_id)
    if not c.username:
        die(EX_USAGE, "Username must not be empty.")
    if c.week and (not is_uint(c.week) or int(c.week) < 1 or int(c.week) > 18):
        die(EX_USAGE, "Week must be an integer between 1 and 18 (got '%s')." % c.week)
    if c.season and (not is_uint(c.season) or len(c.season) != 4):
        die(EX_USAGE, "Season must be a 4 digit year (got '%s')." % c.season)
    if c.season_type not in ("regular", "pre", "post"):
        die(EX_USAGE, "Season type must be regular, pre or post (got '%s')." % c.season_type)
    if not is_uint(c.top_n) or int(c.top_n) < 1 or int(c.top_n) > 50:
        die(EX_USAGE, "Top N must be an integer between 1 and 50 (got '%s')." % c.top_n)
    if c.scoring not in ("ppr", "half", "std", "league"):
        die(EX_USAGE, "Scoring must be ppr, half, std or league (got '%s')." % c.scoring)
    if not is_uint(c.teams) or int(c.teams) < 4 or int(c.teams) > 32:
        die(EX_USAGE, "Teams must be an integer between 4 and 32 (got '%s')." % c.teams)
    if not is_uint(c.horizon) or int(c.horizon) > 6:
        die(EX_USAGE, "Horizon must be an integer between 0 and 6 (got '%s')." % c.horizon)
    if not is_number(c.threshold):
        die(EX_USAGE, "Threshold must be numeric (got '%s')." % c.threshold)
    if not is_number(c.fairness):
        die(EX_USAGE, "Fairness must be numeric (got '%s')." % c.fairness)
    if not is_uint(c.projections_ttl):
        die(EX_USAGE, "Cache TTL must be a non-negative integer (got '%s')." % c.projections_ttl)
    if c.format not in ("text", "json", "markdown"):
        die(EX_USAGE, "Format must be text, json or markdown (got '%s')." % c.format)
    if c.history not in ("0", "1"):
        die(EX_USAGE, "History must be 0 or 1 (got '%s')." % c.history)
    if LOG.level not in ("QUIET", "ERROR", "WARN", "INFO", "DEBUG"):
        die(EX_USAGE, "Log level must be QUIET, ERROR, WARN, INFO or DEBUG (got '%s')." % LOG.level)
    if c.offline == "1":
        if not c.fixtures:
            die(EX_USAGE, "--offline requires --fixtures DIR (or FM_FIXTURES).")
        if not os.path.isdir(c.fixtures):
            die(EX_USAGE, "Fixture directory '%s' does not exist." % c.fixtures)


# --------------------------------------------------------------------------
# Fetch / cache / validate
# --------------------------------------------------------------------------
def json_length(value: Any) -> int:
    return len(value) if isinstance(value, (list, dict, str)) else 0


class Fetcher:
    def __init__(self, c: Config) -> None:
        self.c = c
        self.diagnostics: List[dict] = []
        self.warnings: List[str] = []
        self.data: Dict[str, Any] = {}
        self.source = ""
        self.age: Optional[int] = None
        self.retry_delay = float(os.environ.get("FM_RETRY_DELAY") or 1)

    def add_warning(self, message: str) -> None:
        self.warnings.append(message)
        LOG.warn(message)

    def record(self, key: str, url: str, source: str, age: Optional[int], records: Optional[int], note: str) -> None:
        self.diagnostics.append({"key": key, "url": url, "source": source, "cache_age_seconds": age,
                                 "records": records, "note": note, "at": now_iso()})

    # -- validation -----------------------------------------------------
    @staticmethod
    def parse(raw: bytes, want: str, label: str) -> Tuple[bool, Any]:
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            preview = raw[:120].decode("utf-8", "replace").replace("\n", "")
            LOG.debug("%s: response is not valid JSON (first 120 bytes: %s)" % (label, preview))
            return False, None
        if value is None or value is False:
            LOG.debug("%s: response is not valid JSON (first 120 bytes: %s)"
                      % (label, raw[:120].decode("utf-8", "replace").replace("\n", "")))
            return False, None
        actual = "object" if isinstance(value, dict) else "array" if isinstance(value, list) else (
            "string" if isinstance(value, str) else "boolean" if isinstance(value, bool) else "number")
        if actual not in (want if isinstance(want, tuple) else (want,)):
            LOG.debug("%s: expected JSON %s, got %s" % (label, want, actual))
            return False, None
        if len(value) == 0:
            LOG.debug("%s: %s is empty" % (label, want))
            return False, None
        return True, value

    # -- cache ------------------------------------------------------------
    def cache_path(self, name: str) -> str:
        return os.path.join(self.c.cache_dir, name + ".json")

    @staticmethod
    def cache_age(path: str) -> int:
        return int(time.time()) - int(os.path.getmtime(path))

    def cache_store(self, name: str, raw: bytes) -> None:
        if self.c.no_cache == "1" or not name or name == "-":
            return
        dest = self.cache_path(name)
        tmp = "%s.tmp.%d" % (dest, os.getpid())
        os.makedirs(self.c.cache_dir, exist_ok=True)
        lock = None
        try:
            try:
                import fcntl  # POSIX only; Windows writes are still atomic
                lock = open(os.path.join(self.c.cache_dir, ".lock"), "w")
                fcntl.flock(lock, fcntl.LOCK_EX)
            except (ImportError, OSError):
                lock = None
            with open(tmp, "wb") as fh:
                fh.write(raw)
            os.replace(tmp, dest)
        finally:
            if lock is not None:
                lock.close()
        LOG.debug("Cached %s -> %s" % (name, dest))

    # -- network ----------------------------------------------------------
    def fetch_offline(self, key: str) -> Optional[bytes]:
        status_file = os.path.join(self.c.fixtures, key + ".status")
        src = os.path.join(self.c.fixtures, key + ".json")
        if os.path.isfile(status_file):
            with open(status_file, encoding="utf-8", errors="replace") as fh:
                LOG.debug("Fixture %s simulates HTTP %s" % (key, re.sub(r"\s", "", fh.read())))
            return None
        if not os.path.isfile(src):
            LOG.debug("Fixture %s missing at %s" % (key, src))
            return None
        with open(src, "rb") as fh:
            return fh.read()

    def fetch_url(self, url: str) -> Optional[bytes]:
        """Retries only transient failures (connection errors, 408, 429, 5xx);
        a 404 or other 4xx fails immediately."""
        delay = self.retry_delay
        attempts = 4
        for attempt in range(1, attempts + 1):
            request = urllib.request.Request(url, headers={
                "Accept": "application/json", "User-Agent": "%s/%s" % (TOOL_NAME, TOOL_VERSION)})
            try:
                with urllib.request.urlopen(request, timeout=45) as resp:
                    body = resp.read()
                    status = resp.status
                LOG.debug("HTTP %s %s (%d bytes)" % (status, url, len(body)))
                return body
            except urllib.error.HTTPError as exc:
                status, message = exc.code, ""
                try:
                    message = exc.read()[:200].decode("utf-8", "replace").replace("\n", "")
                except Exception:  # noqa: BLE001
                    pass
                if status in (408, 429) or 500 <= status <= 599:
                    LOG.debug("Transient failure for %s (status %s, attempt %d/%d): %s"
                              % (url, status, attempt, attempts, message or "no message"))
                else:
                    LOG.debug("HTTP %s for %s (not retried); body: %s" % (status, url, message))
                    return None
            except (urllib.error.URLError, OSError, ValueError) as exc:
                LOG.debug("Transient failure for %s (status 000, attempt %d/%d): %s"
                          % (url, attempt, attempts, str(exc)[:300] or "no message"))
            if attempt < attempts:
                time.sleep(delay)
                delay *= 2
        return None

    def fetch_quiet(self, key: str, url: str, want: Any) -> Optional[Any]:
        """One uncached request for history backfill (no per-fetch diagnostic;
        the history database is the cache)."""
        if self.c.offline == "1":
            raw = self.fetch_offline(key)
        else:
            LOG.info("Fetching %s from %s" % (key, url))
            raw = self.fetch_url(url)
        if raw is None:
            return None
        ok, value = self.parse(raw, want, key)
        return value if ok else None

    def fetch_json(self, key: str, url: str, want: str, cache_name: str, ttl: int, allow_stale: bool) -> bool:
        """Leaves validated JSON in self.data[key]; sets self.source / self.age."""
        self.source, self.age = "", None
        cfile = None
        if cache_name and cache_name != "-" and self.c.no_cache != "1":
            cfile = self.cache_path(cache_name)

        # 1. fresh cache
        if cfile and os.path.isfile(cfile) and self.c.refresh != "1":
            age = self.cache_age(cfile)
            if age <= ttl:
                with open(cfile, "rb") as fh:
                    ok, value = self.parse(fh.read(), want, "cache:" + key)
                if ok:
                    self.data[key] = value
                    self.source, self.age = "cache", age
                    LOG.info("Using cached %s (age %ds)" % (key, age))
                    self.record(key, url, "cache", age, json_length(value), "fresh cache")
                    return True

        # 2. fetch
        if self.c.offline == "1":
            raw = self.fetch_offline(key)
        else:
            LOG.info("Fetching %s from %s" % (key, url))
            raw = self.fetch_url(url)
        if raw is not None:
            ok, value = self.parse(raw, want, key)
            if ok:
                self.data[key] = value
                self.cache_store(cache_name, raw)
                self.source = "fixture" if self.c.offline == "1" else "network"
                self.age = 0
                self.record(key, url, self.source, 0, json_length(value), "ok")
                return True

        # 3. stale cache fallback
        if allow_stale and cfile and os.path.isfile(cfile):
            age = self.cache_age(cfile)
            if age <= int(self.c.stale_max_age):
                with open(cfile, "rb") as fh:
                    ok, value = self.parse(fh.read(), want, "stale:" + key)
                if ok:
                    self.data[key] = value
                    self.source, self.age = "stale-cache", age
                    self.add_warning("STALE DATA: '%s' could not be refreshed; using cached copy from %d minutes ago."
                                     % (key, age // 60))
                    self.record(key, url, "stale-cache", age, json_length(value), "stale fallback")
                    return True

        self.record(key, url, "unavailable", None, None, "fetch or validation failed")
        LOG.debug("Could not obtain valid %s for '%s'" % (want, key))
        return False


# --------------------------------------------------------------------------
# Pipeline
# --------------------------------------------------------------------------
def has_projection_records(records: Any) -> bool:
    return isinstance(records, list) and any(
        isinstance(r, dict) and "player_id" in r and isinstance(r.get("stats"), dict) for r in records)


def schedule_week_state(schedule: List[Any], week: int) -> str:
    statuses = [str(alt(g.get("status"), "")).lower() for g in schedule
                if isinstance(g, dict) and ts(alt(g.get("week"), "")) == str(week)]
    if not statuses:
        return "unknown"
    if all(st == "complete" for st in statuses):
        return "complete"
    if any(st in ("complete", "in_game") for st in statuses):
        return "started"
    return "upcoming"


def slim_players(players: Dict[str, Any]) -> Dict[str, Any]:
    """The player database cut down to the fields the analysis needs."""
    out = {}
    for key, value in players.items():
        v = value if isinstance(value, dict) else {}
        name = alt(v.get("full_name"), None)
        if name is None:
            name = s(alt(v.get("first_name"), "")) + " " + s(alt(v.get("last_name"), ""))
        if isinstance(name, str):
            name = name.strip(" ")
        out[key] = {
            "player_id": alt(v.get("player_id"), key),
            "full_name": name,
            "position": v.get("position"),
            "fantasy_positions": alt(v.get("fantasy_positions"), []),
            "team": v.get("team"),
            "status": v.get("status"),
            "injury_status": v.get("injury_status"),
            "injury_notes": v.get("injury_notes"),
            "practice_participation": v.get("practice_participation"),
            "active": v.get("active"),
            "years_exp": v.get("years_exp"),
            "depth_chart_position": v.get("depth_chart_position"),
            "depth_chart_order": v.get("depth_chart_order"),
            "news_updated": v.get("news_updated"),
        }
    return out


def run_pipeline(c: Config) -> dict:
    f = Fetcher(c)
    if c.no_cache != "1":
        try:
            os.makedirs(c.cache_dir, exist_ok=True)
        except OSError:
            die(EX_DATA, "Cannot create cache directory '%s'." % c.cache_dir)
    api = c.api

    # state, schedule and week
    if c.season and c.week:
        LOG.debug("Season and week supplied; /state/nfl still used for provenance")
    state_season = state_week = ""
    if f.fetch_json("state", api + "/state/nfl", "object", "-", 0, False):
        state = f.data["state"]
        if truthy(state.get("season")):
            state_season = ts(state["season"])
        if truthy(state.get("week")):
            state_week = ts(state["week"])
        sst = state.get("season_type")
        if truthy(sst) and ts(sst) != "" and ts(sst) != c.season_type:
            f.add_warning("NFL state reports season type '%s' but '%s' was requested." % (ts(sst), c.season_type))
    else:
        if not c.season or not c.week:
            die(EX_DATA, "Could not load /state/nfl and no --season/--week supplied. Rerun with --season YYYY --week N.")
        f.add_warning("Could not load NFL state; using supplied season/week.")
    season = c.season or state_season
    week_auto = not c.week
    week_text = c.week or state_week
    if not season:
        die(EX_DATA, "Season unavailable from /state/nfl; pass --season YYYY.")
    if not week_text:
        die(EX_DATA, "Week unavailable from /state/nfl; pass --week N.")
    if not is_uint(week_text) or int(week_text) < 1 or int(week_text) > 18:
        die(EX_DATA, "Resolved week '%s' is out of range 1-18; pass --week N." % week_text)
    week = int(week_text)

    schedule_available = False
    sched_url = "%s/%s/%s" % (c.schedule_base, c.season_type, season)
    if f.fetch_json("schedule", sched_url, "array", "schedule_%s_%s" % (season, c.season_type), int(c.schedule_ttl), False) \
            and any(isinstance(g, dict) and all(k in g for k in ("week", "home", "away", "status"))
                    for g in f.data["schedule"]):
        schedule_available = True
        LOG.info("Schedule: %d games" % len(f.data["schedule"]))
    else:
        f.data["schedule"] = []
        f.add_warning("Game schedule unavailable; locked players are detected from live points only (use --locked to add more). If this week's games are over, pass --week to analyse the next week.")
    rolled_from = None
    # /state/nfl keeps reporting a week until midweek. Once every game of that
    # week is final, lineup and waiver advice is only useful for the next one.
    if week_auto and schedule_available and week < 18 and schedule_week_state(f.data["schedule"], week) == "complete":
        rolled_from = week
        week += 1
        LOG.info("Every week %d game is final; analysing week %d instead (pass --week to override)." % (rolled_from, week))
    LOG.info("Season %s, week %d, season type %s" % (season, week, c.season_type))

    # league
    if not f.fetch_json("league", "%s/league/%s" % (api, c.league_id), "object", "-", 0, False):
        die(EX_DATA, "League %s could not be loaded or is not a JSON object. Check the league id." % c.league_id)
    league = f.data["league"]
    if json_length(alt(league.get("roster_positions"), [])) <= 0:
        die(EX_DATA, "League %s has no roster_positions; cannot build a lineup." % c.league_id)
    if not truthy(league.get("scoring_settings")):
        f.add_warning("League has no scoring_settings; projections will fall back to provider aggregate points.")
    if not f.fetch_json("rosters", "%s/league/%s/rosters" % (api, c.league_id), "array", "-", 0, False):
        die(EX_DATA, "League rosters unavailable or empty for league %s." % c.league_id)
    if not f.fetch_json("users", "%s/league/%s/users" % (api, c.league_id), "array", "-", 0, False):
        die(EX_DATA, "League users unavailable or empty for league %s." % c.league_id)
    if not f.fetch_json("matchups", "%s/league/%s/matchups/%d" % (api, c.league_id, week), "array", "-", 0, False):
        f.add_warning("Week %d matchups unavailable; matchup context omitted." % week)
        f.data["matchups"] = []

    # user and roster
    if not f.fetch_json("user", "%s/user/%s" % (api, c.username), "object", "-", 0, False):
        die(EX_DATA, "Sleeper user '%s' could not be resolved. Check --username." % c.username)
    uid_raw = f.data["user"].get("user_id")
    user_id = ts(uid_raw) if truthy(uid_raw) else ""
    if not user_id:
        die(EX_DATA, "Sleeper user '%s' has no user_id in the API response." % c.username)
    rosters = f.data["rosters"]
    mine = next((r for r in rosters if isinstance(r, dict) and r.get("owner_id") == user_id), None)
    if mine is None or not truthy(mine.get("roster_id")):
        mine = next((r for r in rosters if isinstance(r, dict)
                     and user_id in (alt(r.get("co_owners"), []) or [])), None)
    if mine is None or not truthy(mine.get("roster_id")):
        die(EX_DATA, "User '%s' (id %s) does not own a roster in league %s." % (c.username, user_id, c.league_id))
    my_roster_id = mine["roster_id"]
    if isinstance(my_roster_id, str) and is_uint(my_roster_id):
        my_roster_id = int(my_roster_id)
    LOG.info("User %s -> user_id %s, roster_id %s" % (c.username, user_id, ts(my_roster_id)))

    # players
    if not f.fetch_json("players", api + "/players/nfl", "object", "players_nfl", int(c.players_ttl), True):
        die(EX_DATA, "Player database unavailable (network and cache). Retry later or run with --fixtures.")
    players_source, players_age = f.source, f.age
    players = slim_players(f.data["players"])
    LOG.info("Player database: %d players (source %s)" % (len(players), players_source))

    # projections (this week)
    proj_url = "%s/%s/%d?season_type=%s&order_by=pts_ppr" % (c.projections_base, season, week, c.season_type)
    if f.fetch_json("projections", proj_url, "array", "projections_%s_%s_%d" % (season, c.season_type, week),
                    int(c.projections_ttl), True):
        proj_source, proj_age = f.source, f.age
    else:
        die(EX_DATA, "No valid projections for season %s week %d (source: %s). Lineup and waiver analysis need projections; refusing to rank every player at zero." % (season, week, proj_url))
    count = len(f.data["projections"])
    if count < 50:
        f.add_warning("Projection feed returned only %d records; results may be incomplete." % count)
    if not has_projection_records(f.data["projections"]):
        die(EX_DATA, "Projection feed schema changed: no records with 'player_id' and object 'stats' (source: %s)." % proj_url)
    proj_fetched_at = now_iso()
    LOG.info("Projections: %d records (source %s)" % (count, proj_source))

    # future weeks: each optional; a missing week shortens the window
    future: Dict[str, Any] = {}
    future_weeks: List[int] = []
    missing: List[int] = []
    for i in range(1, int(c.horizon) + 1):
        w = week + i
        if w > 18:
            break
        url = "%s/%s/%d?season_type=%s&order_by=pts_ppr" % (c.projections_base, season, w, c.season_type)
        key = "projections_w%d" % w
        if f.fetch_json(key, url, "array", "projections_%s_%s_%d" % (season, c.season_type, w),
                        int(c.projections_ttl), True) and has_projection_records(f.data[key]):
            future[str(w)] = f.data[key]
            future_weeks.append(w)
        else:
            missing.append(w)
    if missing:
        f.add_warning("Projections for week(s) %s unavailable; multi-week values use the remaining weeks."
                      % ", ".join(str(w) for w in missing))
    LOG.info("Future projection weeks: %s" % (",".join(str(w) for w in future_weeks) or "none"))

    # activity
    trending_available = transactions_available = False
    if f.fetch_json("trending_add", api + "/players/nfl/trending/add?lookback_hours=24&limit=100", "array",
                    "trending_add", int(c.trending_ttl), True):
        trending_available = True
    else:
        f.data["trending_add"] = []
        f.add_warning("Trending add data unavailable; the add-trend component is omitted from waiver scoring.")
    if f.fetch_json("transactions", "%s/league/%s/transactions/%d" % (api, c.league_id, week), "array", "-", 0, False):
        transactions_available = True
    else:
        f.data["transactions"] = []
        LOG.debug("No transactions for week %d" % week)

    store = open_history(c, f)
    history, week_flags = load_history(c, f, store, season, week)

    bundle = {
        "config": {
            "tool_version": TOOL_VERSION, "generated_at": now_iso(),
            "league_id": c.league_id, "username": c.username, "user_id": user_id,
            "season": season, "season_type": c.season_type, "week": week,
            "my_roster_id": my_roster_id, "top_n": int(c.top_n),
            "churn_threshold": json_number(c.threshold), "fairness": json_number(c.fairness),
            "skip_waivers": c.skip_waivers == "1", "skip_trades": c.skip_trades == "1",
            "offline": c.offline == "1",
            "locked": [p.strip(" ") for p in c.locked.split(",") if p.strip(" ")],
            "week_rolled_from": rolled_from,
            "horizon": int(c.horizon),
            "custom_trades": c.trade or None,
            "value_trades": c.value_trade or None,
            "value_scoring": c.scoring,
            "value_teams": int(c.teams),
        },
        "provenance": {
            "projections": {"url": proj_url, "source": proj_source, "cache_age_seconds": proj_age,
                            "fetched_at": proj_fetched_at},
            "players": {"source": players_source, "cache_age_seconds": players_age},
            "trending_available": trending_available,
            "transactions_available": transactions_available,
            "schedule_available": schedule_available,
        },
        "warnings": list(f.warnings),
        "league": league, "rosters": rosters, "users": f.data["users"],
        "matchups": f.data["matchups"], "players": players, "projections": f.data["projections"],
        "trending_add": f.data["trending_add"], "transactions": f.data["transactions"],
        "schedule": f.data["schedule"],
        "future_projections": future,
        "history": history,
        "diagnostics": f.diagnostics,
    }

    def persist(analyzer: Any) -> None:
        if store is None:
            return
        updates = dict(getattr(analyzer, "history_updates", None) or {})
        updates["weeks"] = week_flags
        try:
            store.save(c.league_id, season, updates)
        except Exception as exc:  # noqa: BLE001
            LOG.warn("Could not save history: %s" % exc)
        finally:
            store.close()

    return run_analysis(bundle, persist)


# --------------------------------------------------------------------------
# History (past weeks: projections vs actual points)
# --------------------------------------------------------------------------
def open_history(c: Config, f: Fetcher) -> Optional[fm_history.HistoryStore]:
    if c.history != "1":
        return None
    path = c.history_db or (":memory:" if c.no_cache == "1" else os.path.join(c.cache_dir, "history.sqlite"))
    try:
        if path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        return fm_history.HistoryStore(path)
    except Exception as exc:  # noqa: BLE001
        f.add_warning("History database '%s' unavailable (%s); past weeks are not saved this run." % (path, exc))
        return fm_history.HistoryStore(":memory:")


def load_history(c: Config, f: Fetcher, store: Optional[fm_history.HistoryStore], season: str,
                 week: int) -> Tuple[Optional[dict], Dict[int, dict]]:
    """Stored rows plus raw data for past weeks not yet in the database.
    Each past week is fetched once; parts that failed are retried at most
    once a day (--refresh retries now and refetches last week's results)."""
    if store is None:
        return None, {}
    status = store.week_status(c.league_id, season)
    now = time.time()
    raw: Dict[str, dict] = {}
    flags: Dict[int, dict] = {}
    stored = fetched = 0
    stats_missing: List[int] = []
    weeks = list(range(1, week)) if c.season_type == "regular" else []
    for w in weeks:
        st = status.get(w) or {}
        retry = not st or c.refresh == "1" or now - (st.get("attempted_at") or 0) >= 86400
        latest = c.refresh == "1" and w == week - 1
        need_proj = retry and not st.get("projections_ok")
        need_act = (retry and not st.get("actuals_ok")) or latest
        need_stats = (retry and not st.get("stats_ok")) or latest
        if not (need_proj or need_act or need_stats):
            stored += 1
            if not st.get("stats_ok"):
                stats_missing.append(w)
            continue
        entry: Dict[str, Any] = {}
        week_flag = {}
        if need_proj:
            url = "%s/%s/%d?season_type=%s&order_by=pts_ppr" % (c.projections_base, season, w, c.season_type)
            value = f.fetch_quiet("projections_w%d" % w, url, "array")
            if value is not None and has_projection_records(value):
                entry["projections"] = value
                week_flag["projections_ok"] = True
        if need_act:
            value = f.fetch_quiet("matchups_w%d" % w, "%s/league/%s/matchups/%d" % (c.api, c.league_id, w), "array")
            if value is not None and any(isinstance(m, dict) and isinstance(m.get("players_points"), dict)
                                         for m in value):
                entry["matchups"] = value
                week_flag["actuals_ok"] = True
        if need_stats:
            url = "%s/%s/%d?season_type=%s" % (c.stats_base, season, w, c.season_type)
            value = f.fetch_quiet("stats_w%d" % w, url, ("array", "object"))
            if value is not None:
                entry["stats"] = value
                week_flag["stats_ok"] = True
            elif not st.get("stats_ok"):
                stats_missing.append(w)
        flags[w] = week_flag
        if entry:
            raw[str(w)] = entry
            fetched += 1
    data = store.load(c.league_id, season)
    note = "%s; %d stored, %d fetched" % (
        "weeks 1-%d" % (week - 1) if week > 2 else ("week 1" if week == 2 else "no past weeks"), stored, fetched)
    if stats_missing:
        note += "; no stats feed for week %s (rostered players only)" % ", ".join(str(w) for w in stats_missing)
    source = ("fixture" if c.offline == "1" else "network") if fetched else ("database" if stored else "unavailable")
    if weeks and not fetched and not stored:
        note = "weeks 1-%d: no past results available" % (week - 1) if week > 2 else "week 1: no results available"
    f.record("history", store.path, source, None, len(weeks), note)
    return {"weeks": weeks, "stored": data, "raw": raw, "stats_missing": stats_missing,
            "database": store.path}, flags


def run_analysis(bundle: dict, persist: Any = None) -> dict:
    try:
        analyzer = fm_analysis.Analyzer(bundle)
        report = analyzer.run()
    except Exception:  # noqa: BLE001
        LOG.error("Analysis failed: %s" % traceback.format_exc()[-1000:])
        raise Exit(EX_DATA)
    if persist is not None:
        persist(analyzer)
    if not isinstance(report, dict) or "lineup" not in report:
        die(EX_DATA, "Analysis produced an invalid report.")
    # Same key order and number forms the report has always been rendered from.
    return json.loads(json.dumps(report, sort_keys=True))


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------
LINE = "-" * 72
SCORING_NAMES = {"ppr": "PPR", "half": "half-PPR", "std": "standard", "league": "league scoring"}


def player_text(p: Optional[dict]) -> str:
    if p is None:
        return "(empty)"
    return alt(p.get("name"), "unknown") + " " + "(" + alt(p.get("position"), "?") + "/" + alt(p.get("team"), "FA") + ")"


def player_md(p: Optional[dict]) -> str:
    if p is None:
        return "_(empty)_"
    return alt(p.get("name"), "unknown") + " (" + alt(p.get("position"), "?") + "/" + alt(p.get("team"), "FA") + ")"


def minutes(age: Any) -> str:
    return num(math.floor(age / 60))


def locks_list(lineup: dict) -> List[dict]:
    locks = lineup.get("locks") or {}
    return list(alt(locks.get("locked_starters"), []) or []) + list(alt(locks.get("locked_bench"), []) or [])


def weights_text(weights: dict) -> str:
    return ", ".join(k + " " + num(c_round(v * 100)) + "%" for k, v in weights.items())


def side_labels(t: dict) -> Tuple[bool, str, str]:
    side_a = t.get("side_a")
    is_me = True if side_a is None else side_a.get("is_me")
    partner = t.get("partner") or {}
    a = "you" if truthy(is_me) else alt(side_a.get("team"), "side A")
    b = "them" if truthy(is_me) else alt(partner.get("team"), "side B")
    return truthy(is_me), a, b


def join_status(row: dict) -> str:
    return ", ".join(ts(x) for x in (row.get("status"), row.get("injury_status"), row.get("practice_participation"))
                     if x is not None)


def render_text(r: dict) -> str:
    m = r["metadata"]
    out: List[str] = [
        "=" * 72,
        "FANTASY MANAGER - " + alt(m.get("league_name"), "league") + " - Week " + ts(m["week"]) + " ("
        + m["season"] + " " + m["season_type"] + ")",
        "Manager: " + m["username"] + "   Team: " + alt(m.get("team_name"), "n/a"),
        "Generated: " + m["generated_at"] + "   Tool: fantasy_manager " + m["tool_version"],
        "=" * 72,
        "",
    ]
    if m.get("week_rolled_from") is not None:
        out += ["NOTE: every week " + ts(m["week_rolled_from"]) + " game is final, so this report is for week "
                + ts(m["week"]) + " (pass --week to override).", ""]
    p = m["projections"]
    out += [
        "SCORING: " + m["scoring"]["mode"] + " (source: " + m["scoring"]["source"] + ")",
        "PROJECTIONS: " + p["source"] + " | " + p["url"],
        "  fetched " + alt(p.get("fetched_at"), "n/a")
        + " | cache age " + ("n/a" if p.get("cache_age_seconds") is None else minutes(p["cache_age_seconds"]) + "m")
        + " | records " + ts(p.get("record_count"))
        + ("  *** STALE ***" if truthy(p.get("stale")) else ""),
        "",
    ]
    if len(r["warnings"]) > 0:
        out += ["WARNINGS", LINE] + ["  ! " + w for w in r["warnings"]] + [""]

    lu = r["lineup"]
    out += ["LINEUP - week " + ts(m["week"]), LINE,
            "  Current projected:   " + n1(lu.get("current_points")),
            "  Optimal projected:   " + n1(lu.get("optimal_points")),
            "  Potential gain:      " + n1(lu.get("gain"))]
    locked = locks_list(lu)
    if len(locked) > 0:
        out += ["  Locked (game started, cannot move): " + ", ".join(s(x.get("name")) for x in locked),
                "  Lock source: " + lu["locks"]["source"]]
    out += [""]
    out += ["  " + pad("SLOT", 12) + pad("CURRENT", 26) + pad("RECOMMENDED", 26) + pad("ACTION", 12) + "GAIN"]
    for sl in lu["slots"]:
        out.append("  " + pad(sl["slot"], 12) + pad(player_text(sl.get("current")), 26)
                   + pad(player_text(sl.get("recommended")), 26) + pad(sl["action"], 12) + n1(sl.get("gain"))
                   + ("  (optional)" if truthy(sl.get("below_threshold")) else ""))
    out += [""]
    if len(lu["risk"]) > 0:
        out += ["  RISK / AVAILABILITY"]
        for rk in lu["risk"]:
            out.append("    - " + s(rk.get("name")) + " (" + alt(rk.get("position"), "?") + "): " + join_status(rk)
                       + ("" if rk.get("note") is None else " - " + rk["note"]))
        out += [""]

    mu = r.get("matchup")
    if mu is None:
        out += ["MATCHUP: unavailable", ""]
    else:
        out += ["MATCHUP", LINE,
                "  " + alt(mu.get("my_team"), "me") + "  vs  " + alt(mu.get("opponent_team"), "unknown"),
                "  Projected (current lineups): " + n1(mu.get("my_projected")) + "  vs  " + n1(mu.get("opponent_projected")),
                "  Differential: " + n1(mu.get("differential")),
                "  Live/final points: " + n1(mu.get("my_points")) + "  vs  " + n1(mu.get("opponent_points")),
                "  Projected final (live + remaining): " + n1(mu.get("my_projected_final")) + "  vs  "
                + n1(mu.get("opponent_projected_final")) + "  (" + n1(mu.get("final_differential")) + ")",
                "  Note: " + mu["note"], ""]

    wv = r.get("waivers")
    if wv is None:
        out += ["WAIVERS: skipped", ""]
    else:
        wa = wv["waiver"]
        ww = alt(wv.get("window_weeks"), []) or []
        out += ["WAIVERS", LINE,
                "  Waiver type: " + wa["type"]
                + ("" if wa.get("budget") is None else "  budget " + ts(wa["budget"]) + ", remaining " + ts(wa.get("remaining"))),
                "  Weights: " + weights_text(wv["weights_used"]),
                "  Window: " + ("weeks " + ", ".join(ts(w) for w in ww) + " (\"win\" = gain over all of them)"
                                if len(ww) > 1 else "this week only"),
                "  Omitted components: " + ("none" if len(wv["omitted_components"]) == 0
                                            else ", ".join(wv["omitted_components"])),
                ""]
        for title, key in (("PRIORITY CLAIMS", "priority"), ("BENCH UPGRADES / STASHES", "bench_upgrades"),
                           ("STREAMERS", "streamers"), ("AVOID", "avoid")):
            rows = wv["groups"][key]
            out.append("  " + title)
            if len(rows) == 0:
                out.append("    (none)")
            for row in rows:
                out.append("    " + pad(s(row.get("name")) + " (" + alt(row.get("position"), "?") + "/" + alt(row.get("team"), "FA") + ")", 30)
                           + "proj " + pad(n1(row.get("projection")), 7)
                           + "net " + pad(n1(row.get("net_gain")), 7)
                           + ("" if row.get("window_gain") is None else "win " + pad(n1(row.get("window_gain")), 7))
                           + "score " + pad(n1(row.get("score")), 7)
                           + ("" if row.get("recent") is None
                              else "form " + n1(row["recent"].get("avg_points")) + "/" + n1(row["recent"].get("avg_projection")) + " ")
                           + ("" if row.get("suggested_bid") is None
                              else "bid $" + ts(row["suggested_bid"]) + " (" + ts(row.get("suggested_bid_pct")) + "% est) ")
                           + ("" if row.get("drop_candidate") is None else "drop " + s(row["drop_candidate"].get("name")))
                           + (" [" + "; ".join(row["notes"]) + "]" if len(row.get("notes") or []) > 0 else ""))
            out.append("")

    tr = r.get("trades")
    if tr is None:
        out += ["TRADES: skipped", ""]
    else:
        needs = tr["my_needs"]
        surplus = tr["my_surplus"]
        out += ["TRADES", LINE,
                "  My needs:   " + ("none identified" if len(needs) == 0 else ", ".join(
                    x["position"] + " (" + n1(x.get("starter_points")) + " vs league " + n1(x.get("league_average")) + ")"
                    for x in needs)),
                "  My surplus: " + ("none identified" if len(surplus) == 0 else ", ".join(
                    s(x.get("name")) + " (" + alt(x.get("position"), "?") + ", cost " + n1(x.get("lineup_cost")) + ")"
                    for x in surplus)),
                ""]
        if len(tr["partners"]) == 0:
            out += ["  No balanced packages found within the fairness tolerance.", ""]
        for pt in tr["partners"]:
            out.append("  " + alt(pt.get("team"), "roster " + ts(pt.get("roster_id")))
                       + "  needs: " + ("none" if len(pt["needs"]) == 0 else ", ".join(x["position"] for x in pt["needs"])))
            out.append("    depth before: " + ", ".join(k + " " + n1(v) for k, v in pt["depth_before"].items()))
            if len(pt["packages"]) == 0:
                out.append("    (no balanced package)")
            for pk in pt["packages"]:
                out.append("    GIVE " + " + ".join(s(g.get("name")) + " (" + alt(g.get("position"), "?") + ")" for g in pk["give"])
                           + "  GET " + " + ".join(s(g.get("name")) + " (" + alt(g.get("position"), "?") + ")" for g in pk["get"])
                           + "  | my gain " + n1(pk.get("my_gain")) + ", their gain " + n1(pk.get("their_gain"))
                           + (" over " + ts(pk["window_weeks"]) + " wks (this wk " + n1(pk.get("my_gain_this_week")) + ")"
                              if alt(pk.get("window_weeks"), 1) > 1 else "")
                           + ", fairness gap " + n1(pk.get("fairness_gap")))
            out.append("")

    if r.get("custom_trades") is not None:
        out += ["TRADE ANALYZER", LINE]
        for t in r["custom_trades"]:
            if t.get("error") is not None:
                out += ["  " + t["input"], "    ERROR: " + t["error"], ""]
                continue
            is_me, a, b = side_labels(t)
            partner = t.get("partner") or {}
            nw = ts(len(t["window_weeks"]))
            out += [
                "  " + t["input"] + "  (" + ("with " + alt(partner.get("team"), "roster " + ts(partner.get("roster_id")))
                                             if is_me else a + " <-> " + b) + ")",
                "    GRADE  " + a + " " + pad(t["my_grade"], 4) + b + " " + pad(t["their_grade"], 4)
                + "acceptance: " + t["acceptance"],
                "    " + t["verdict"],
                "    gain per week: " + a + " " + n1(t.get("my_gain_per_week")) + ", " + b + " " + n1(t.get("their_gain_per_week"))
                + "   over weeks " + ", ".join(ts(w) for w in t["window_weeks"]) + ": " + a + " " + n1(t.get("my_gain"))
                + ", " + b + " " + n1(t.get("their_gain")),
                "    weekly (" + a + "): " + " / ".join(n1(x) for x in t["my_weekly_gains"]),
                "    give: " + ", ".join(s(g.get("name")) + " (" + alt(g.get("position"), "?") + ", starts "
                                         + ts(alt(g.get("weeks_started_before"), 0)) + "/" + nw + " wks now)" for g in t["give"]),
                "    get:  " + ", ".join(s(g.get("name")) + " (" + alt(g.get("position"), "?") + ", would start "
                                         + ts(alt(g.get("weeks_started_after"), 0)) + "/" + nw + ")" for g in t["get"]),
            ]
            out += ["    - " + x for x in t["notes"]] + ["    ! " + x for x in t["flags"]] + [""]

    if r.get("value_trades") is not None:
        out += ["ANY-PLAYER TRADES", LINE]
        for t in r["value_trades"]:
            if t.get("error") is not None:
                out += ["  " + t["input"], "    ERROR: " + t["error"], ""]
                continue
            out += [
                "  " + t["input"] + "  (" + alt(SCORING_NAMES.get(t["scoring"]), t["scoring"]) + ", " + ts(t["teams"])
                + " teams, weeks " + ", ".join(ts(w) for w in t["window_weeks"]) + ")",
                "    GRADE  side A " + pad(t["my_grade"], 4) + "side B " + pad(t["their_grade"], 4) + "acceptance (B): " + t["acceptance"],
                "    " + t["verdict"],
                "    value over replacement per week: side A " + n1(t.get("my_gain_per_week")) + ", side B " + n1(t.get("their_gain_per_week")),
                "    side A gives: " + ", ".join(s(g.get("name")) + " (" + alt(g.get("position"), "?") + "/" + alt(g.get("team"), "FA")
                                                 + ", " + n1(g.get("value_over_replacement")) + " above repl.)" for g in t["give"]),
                "    side B gives: " + ", ".join(s(g.get("name")) + " (" + alt(g.get("position"), "?") + "/" + alt(g.get("team"), "FA")
                                                 + ", " + n1(g.get("value_over_replacement")) + " above repl.)" for g in t["get"]),
            ]
            out += ["    - " + x for x in t["notes"]] + ["    ! " + x for x in t["flags"]] + [""]

    out += history_text(r.get("history"))
    out += ["DIAGNOSTICS", LINE]
    for d in r["diagnostics"]["fetches"]:
        out.append("  " + pad(d["key"], 16) + pad(d["source"], 14)
                   + ("" if d.get("cache_age_seconds") is None else "age " + minutes(d["cache_age_seconds"]) + "m  ")
                   + ("" if d.get("records") is None else ts(d["records"]) + " records  ")
                   + d["note"])
    out += ["",
            "This tool is read-only: it cannot submit lineups, waiver claims or trades.",
            "Projections are advisory; no correlation or game-script modelling is performed."]
    return "\n".join(out) + "\n"


def render_markdown(r: dict) -> str:
    m = r["metadata"]
    p = m["projections"]
    out: List[str] = [
        "# Fantasy Manager - " + alt(m.get("league_name"), "league") + " - Week " + ts(m["week"]),
        "",
        "- Season: " + m["season"] + " (" + m["season_type"] + ")"
        + ("" if m.get("week_rolled_from") is None
           else " - week " + ts(m["week_rolled_from"]) + " is final, showing week " + ts(m["week"])),
        "- Manager: " + m["username"] + " - Team: " + alt(m.get("team_name"), "n/a"),
        "- Generated: " + m["generated_at"] + " by fantasy_manager " + m["tool_version"],
        "- Scoring: " + m["scoring"]["mode"] + " (source: " + m["scoring"]["source"] + ")",
        "- Projections: " + p["source"] + " - `" + p["url"] + "` - " + ts(p.get("record_count")) + " records"
        + (" - **STALE**" if truthy(p.get("stale")) else ""),
        "",
    ]
    if len(m["scoring"]["unsupported_keys"]) > 0:
        out += ["> Unsupported scoring keys (no matching projection stat): " + ", ".join(m["scoring"]["unsupported_keys"]), ""]
    if len(r["warnings"]) > 0:
        out += ["## Warnings", ""] + ["- " + w for w in r["warnings"]] + [""]
    lu = r["lineup"]
    out += ["## Lineup", "",
            "| Metric | Points |", "| --- | ---: |",
            "| Current | " + n1(lu.get("current_points")) + " |",
            "| Optimal | " + n1(lu.get("optimal_points")) + " |",
            "| Gain | " + n1(lu.get("gain")) + " |",
            ""]
    locked = locks_list(lu)
    if len(locked) > 0:
        out += ["Locked (game started): " + ", ".join(s(x.get("name")) for x in locked)
                + " _(" + lu["locks"]["source"] + ")_", ""]
    out += ["| Slot | Current | Recommended | Action | Gain |", "| --- | --- | --- | --- | ---: |"]
    for sl in lu["slots"]:
        out.append("| " + sl["slot"] + " | " + player_md(sl.get("current")) + " | " + player_md(sl.get("recommended"))
                   + " | " + sl["action"] + (" (optional)" if truthy(sl.get("below_threshold")) else "")
                   + " | " + n1(sl.get("gain")) + " |")
    out += [""]
    if len(lu["risk"]) > 0:
        out += ["### Availability risk", ""]
        for rk in lu["risk"]:
            out.append("- **" + s(rk.get("name")) + "** (" + alt(rk.get("position"), "?") + "): " + join_status(rk))
        out += [""]

    mu = r.get("matchup")
    if mu is None:
        out += ["## Matchup", "", "Matchup data unavailable.", ""]
    else:
        out += ["## Matchup", "",
                "| Team | Projected (current lineup) | Live points |",
                "| --- | ---: | ---: |",
                "| " + alt(mu.get("my_team"), "me") + " | " + n1(mu.get("my_projected")) + " | " + n1(mu.get("my_points")) + " |",
                "| " + alt(mu.get("opponent_team"), "unknown") + " | " + n1(mu.get("opponent_projected")) + " | "
                + n1(mu.get("opponent_points")) + " |",
                "", "Differential: " + n1(mu.get("differential")),
                "", "Projected final (live + remaining): " + n1(mu.get("my_projected_final")) + " vs "
                + n1(mu.get("opponent_projected_final")),
                "", "> " + mu["note"], ""]

    wv = r.get("waivers")
    if wv is not None:
        wa = wv["waiver"]
        ww = alt(wv.get("window_weeks"), []) or []
        out += ["## Waivers", "",
                "- Waiver type: " + wa["type"]
                + ("" if wa.get("budget") is None else " (budget " + ts(wa["budget"]) + ", remaining " + ts(wa.get("remaining")) + ")"),
                "- Weights: " + weights_text(wv["weights_used"]),
                "- Window: " + ("weeks " + ", ".join(ts(w) for w in ww) if len(ww) > 1 else "this week only"),
                "- Omitted components: " + ("none" if len(wv["omitted_components"]) == 0 else ", ".join(wv["omitted_components"])),
                ""]
        for title, key in (("Priority claims", "priority"), ("Bench upgrades / stashes", "bench_upgrades"),
                           ("Streamers", "streamers"), ("Avoid", "avoid")):
            rows = wv["groups"][key]
            out += ["### " + title, "",
                    "| Player | Pos | Team | Proj | Net gain | Window gain | Score | Bid (est) | Drop |",
                    "| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |"]
            if len(rows) == 0:
                out.append("| _(none)_ | | | | | | | | |")
            for row in rows:
                out.append("| " + s(row.get("name")) + " | " + alt(row.get("position"), "?") + " | " + alt(row.get("team"), "FA")
                           + " | " + n1(row.get("projection")) + " | " + n1(row.get("net_gain")) + " | " + n1(row.get("window_gain"))
                           + " | " + n1(row.get("score"))
                           + " | " + ("n/a" if row.get("suggested_bid") is None
                                      else "$" + ts(row["suggested_bid"]) + " (" + ts(row.get("suggested_bid_pct")) + "%)")
                           + " | " + ("n/a" if row.get("drop_candidate") is None else s(row["drop_candidate"].get("name"))) + " |")
            out.append("")

    tr = r.get("trades")
    if tr is not None:
        out += ["## Trades", "",
                "- My needs: " + ("none identified" if len(tr["my_needs"]) == 0 else ", ".join(x["position"] for x in tr["my_needs"])),
                "- My surplus: " + ("none identified" if len(tr["my_surplus"]) == 0
                                    else ", ".join(s(x.get("name")) for x in tr["my_surplus"])),
                ""]
        if len(tr["partners"]) == 0:
            out += ["No balanced packages found within the fairness tolerance.", ""]
        for pt in tr["partners"]:
            out += ["### " + alt(pt.get("team"), "roster " + ts(pt.get("roster_id"))), "",
                    "- Needs: " + ("none" if len(pt["needs"]) == 0 else ", ".join(x["position"] for x in pt["needs"])), ""]
            if len(pt["packages"]) == 0:
                out += ["_No balanced package._", ""]
            else:
                out += ["| Give | Get | My gain (window) | Their gain (window) | My gain this week | Fairness gap |",
                        "| --- | --- | ---: | ---: | ---: | ---: |"]
                for pk in pt["packages"]:
                    out.append("| " + " + ".join(s(g.get("name")) for g in pk["give"]) + " | "
                               + " + ".join(s(g.get("name")) for g in pk["get"])
                               + " | " + n1(pk.get("my_gain")) + " | " + n1(pk.get("their_gain")) + " | "
                               + n1(pk.get("my_gain_this_week")) + " | " + n1(pk.get("fairness_gap")) + " |")
                out += [""]

    if r.get("custom_trades") is not None:
        out += ["## Trade analyzer", ""]
        for t in r["custom_trades"]:
            if t.get("error") is not None:
                out += ["### " + t["input"], "", "**Error:** " + t["error"], ""]
                continue
            is_me, _, _ = side_labels(t)
            side_a = t.get("side_a") or {}
            partner = t.get("partner") or {}
            if is_me:
                head = ("With " + alt(partner.get("team"), "roster " + ts(partner.get("roster_id"))) + ". **Your grade: "
                        + t["my_grade"] + "**, their grade: " + t["their_grade"] + ", acceptance: " + t["acceptance"] + ".")
                table_head = "| | You | Them |"
            else:
                a_name = alt(side_a.get("team"), "Side A")
                b_name = alt(partner.get("team"), "Side B")
                head = (a_name + " <-> " + b_name + ". **" + a_name + ": " + t["my_grade"] + "**, **" + b_name + ": "
                        + t["their_grade"] + "**, acceptance: " + t["acceptance"] + ".")
                table_head = "| | " + a_name + " | " + b_name + " |"
            out += ["### " + t["input"], "", head, "", t["verdict"], "", table_head, "| --- | ---: | ---: |",
                    "| Gain per week | " + n1(t.get("my_gain_per_week")) + " | " + n1(t.get("their_gain_per_week")) + " |",
                    "| Gain over weeks " + ", ".join(ts(w) for w in t["window_weeks"]) + " | " + n1(t.get("my_gain"))
                    + " | " + n1(t.get("their_gain")) + " |",
                    "",
                    "- Give: " + ", ".join(s(g.get("name")) + " (" + alt(g.get("position"), "?") + ")" for g in t["give"]),
                    "- Get: " + ", ".join(s(g.get("name")) + " (" + alt(g.get("position"), "?") + ")" for g in t["get"])]
            out += ["- " + x for x in t["notes"]] + ["- **" + x + "**" for x in t["flags"]] + [""]

    if r.get("value_trades") is not None:
        out += ["## Any-player trades", ""]
        for t in r["value_trades"]:
            if t.get("error") is not None:
                out += ["### " + t["input"], "", "**Error:** " + t["error"], ""]
                continue
            out += ["### " + t["input"], "",
                    "**Side A: " + t["my_grade"] + "**, **Side B: " + t["their_grade"] + "**, acceptance (side B): " + t["acceptance"]
                    + ". " + alt(SCORING_NAMES.get(t["scoring"]), t["scoring"]) + ", " + ts(t["teams"]) + " teams, weeks "
                    + ", ".join(ts(w) for w in t["window_weeks"]) + ".", "",
                    t["verdict"], "",
                    "| Side A gives | Pos | Team | Points | Above repl. |", "| --- | --- | --- | ---: | ---: |"]
            out += ["| " + s(g.get("name")) + " | " + alt(g.get("position"), "?") + " | " + alt(g.get("team"), "FA") + " | "
                    + n1(g.get("window_points")) + " | " + n1(g.get("value_over_replacement")) + " |" for g in t["give"]]
            out += ["", "| Side B gives | Pos | Team | Points | Above repl. |", "| --- | --- | --- | ---: | ---: |"]
            out += ["| " + s(g.get("name")) + " | " + alt(g.get("position"), "?") + " | " + alt(g.get("team"), "FA") + " | "
                    + n1(g.get("window_points")) + " | " + n1(g.get("value_over_replacement")) + " |" for g in t["get"]]
            out += [""] + ["- " + x for x in t["notes"]] + ["- **" + x + "**" for x in t["flags"]] + [""]

    out += history_markdown(r.get("history"))
    out += ["## Diagnostics", "", "| Source | Origin | Cache age | Records | Note |", "| --- | --- | --- | ---: | --- |"]
    for d in r["diagnostics"]["fetches"]:
        out.append("| " + d["key"] + " | " + d["source"] + " | "
                   + ("n/a" if d.get("cache_age_seconds") is None else minutes(d["cache_age_seconds"]) + "m")
                   + " | " + ("n/a" if d.get("records") is None else ts(d["records"])) + " | " + d["note"] + " |")
    out += ["",
            "> Read-only tool: it cannot submit lineups, waiver claims or trades.",
            "> Projections are advisory and do not model correlation or game script."]
    return "\n".join(out) + "\n"


def signed(v: Any) -> str:
    """One decimal with a sign: +0.9, -1.2, 0."""
    if v is None:
        return "n/a"
    text = n1(v)
    if text in ("0", "-0"):
        return "0"
    return text if text.startswith("-") else "+" + text


def weeks_label(weeks: List[Any]) -> str:
    if not weeks:
        return "no weeks"
    if len(weeks) > 1 and weeks == list(range(weeks[0], weeks[-1] + 1)):
        return "weeks %s-%s" % (ts(weeks[0]), ts(weeks[-1]))
    return ("week " if len(weeks) == 1 else "weeks ") + ", ".join(ts(w) for w in weeks)


def history_rows(h: dict) -> List[Tuple[str, dict]]:
    acc = h["accuracy"]
    rows = [(pos, s) for pos, s in acc["by_position"].items() if s is not None]
    if acc.get("overall") is not None:
        rows.append(("ALL", acc["overall"]))
    return rows


def history_text(h: Optional[dict]) -> List[str]:
    if h is None:
        return []
    if not h["available"]:
        return ["HISTORY: unavailable - " + s(h.get("reason")), ""]
    out = ["HISTORY - " + weeks_label(h["weeks"]) + " (projected vs actual, league scoring)", LINE,
           "  Projection accuracy (player-weeks projected " + n1(h.get("min_projection")) + "+ points):",
           "    " + pad("POS", 6) + pad("N", 6) + pad("AVG MISS", 10) + pad("BIAS", 7) + "WITHIN 5"]
    for pos, st in history_rows(h):
        out.append("    " + pad(pos, 6) + pad(st["n"], 6) + pad(n1(st.get("mae")), 10) + pad(signed(st.get("bias")), 7)
                   + ts(st.get("within_5_pct")) + "%")
    src = h["projection_sources"]
    out.append("  Projections compared: " + ts(src.get("snapshot", 0)) + " recorded before kickoff, "
               + ts(src.get("backfill", 0)) + " fetched afterwards. Bias > 0: players beat projections.")
    if h.get("stats_missing_weeks"):
        out.append("  ! No stats feed for " + weeks_label(h["stats_missing_weeks"])
                   + ": only rostered players have results there.")
    if h.get("my_roster"):
        out += ["", "  YOUR ROSTER - recent form (last 4 weeks played)",
                "    " + pad("PLAYER", 30) + pad("GP", 4) + pad("AVG", 7) + pad("PROJ", 7) + pad("BEAT", 6) + "WEEKLY (actual)"]
        for pid in h["my_roster"]:
            p = h["players"][pid]
            out.append("    " + pad(s(p.get("name")) + " (" + alt(p.get("position"), "?") + "/" + alt(p.get("team"), "FA") + ")", 30)
                       + pad(p["games"], 4) + pad(n1(p.get("avg_points")), 7) + pad(n1(p.get("avg_projection")), 7)
                       + pad(ts(p.get("beat")) + "/" + ts(p.get("compared")), 6)
                       + " ".join(n1(x.get("actual")) for x in p["last"]))
    return out + [""]


def history_markdown(h: Optional[dict]) -> List[str]:
    if h is None:
        return []
    if not h["available"]:
        return ["## History", "", "Unavailable: " + s(h.get("reason")), ""]
    src = h["projection_sources"]
    out = ["## History", "",
           "Projected vs actual points, " + weeks_label(h["weeks"]) + ", league scoring. "
           + ts(src.get("snapshot", 0)) + " projections recorded before kickoff, " + ts(src.get("backfill", 0))
           + " fetched afterwards.", "",
           "| Position | Player-weeks | Avg miss | Bias | Within 5 |", "| --- | ---: | ---: | ---: | ---: |"]
    for pos, st in history_rows(h):
        out.append("| " + pos + " | " + ts(st["n"]) + " | " + n1(st.get("mae")) + " | " + signed(st.get("bias"))
                   + " | " + ts(st.get("within_5_pct")) + "% |")
    out.append("")
    if h.get("stats_missing_weeks"):
        out += ["> No stats feed for " + weeks_label(h["stats_missing_weeks"]) + ": only rostered players have results there.", ""]
    if h.get("my_roster"):
        out += ["### Your roster: recent form", "",
                "| Player | Pos | GP | Avg | Proj | Beat | Weekly (actual) |", "| --- | --- | ---: | ---: | ---: | ---: | --- |"]
        for pid in h["my_roster"]:
            p = h["players"][pid]
            out.append("| " + s(p.get("name")) + " | " + alt(p.get("position"), "?") + " | " + ts(p["games"]) + " | "
                       + n1(p.get("avg_points")) + " | " + n1(p.get("avg_projection")) + " | " + ts(p.get("beat")) + "/"
                       + ts(p.get("compared")) + " | " + " / ".join(n1(x.get("actual")) for x in p["last"]) + " |")
        out.append("")
    return out


def render_json(r: dict) -> str:
    return json.dumps(r, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def write_stdout(text: str) -> None:
    data = text.encode("utf-8")
    try:
        sys.stdout.buffer.write(data)
    except AttributeError:
        sys.stdout.write(text)
    sys.stdout.flush()


def print_config(c: Config) -> None:
    keys = ("config_file", "league_id", "username", "week", "season", "season_type", "horizon", "top_n",
            "threshold", "fairness", "scoring", "teams", "locked", "format", "output", "cache_dir")
    out = {k: getattr(c, k) for k in keys}
    out["log_level"] = LOG.level
    write_stdout(json.dumps(out, indent=2) + "\n")


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        cli = parse_args(argv)
        c = load_configuration(cli)
        if c.print_config:
            print_config(c)
            return EX_OK
        if os.name != "nt":
            os.umask(0o077)
        if c.log_file:
            try:
                os.makedirs(os.path.dirname(os.path.abspath(c.log_file)), exist_ok=True)
            except OSError:
                pass
            LOG.file = c.log_file
        report = run_pipeline(c)
        renderer = {"json": render_json, "text": render_text, "markdown": render_markdown}[c.format]
        rendered = renderer(report)
        if c.output == "-":
            write_stdout(rendered)
        else:
            try:
                os.makedirs(os.path.dirname(os.path.abspath(c.output)), exist_ok=True)
            except OSError:
                pass
            with open(c.output, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(rendered)
            LOG.info("Report written to %s" % c.output)
        return EX_OK
    except Exit as exc:
        return exc.code
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
