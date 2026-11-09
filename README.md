# fantasy_manager

Weekly decision support for a Sleeper fantasy football team: start/sit, waivers
and trade frameworks. The tool is **read-only** — it reads public Sleeper data
and prints a report. It cannot submit lineups, waiver claims or trades.

Bret can run it with no arguments; the league id and username are compiled in as
defaults (`1400680781302525952` / `MaTrasaMaae`).

```bash
./fantasy_manager.sh                # text report for the current week
./fantasy_manager.sh --format json  # machine readable
```

## Layout

| Path | Purpose |
| --- | --- |
| `fantasy_manager.sh` | CLI, configuration, fetching, caching, validation, rendering |
| `lib/fm_analysis.py` | Pure analysis: scoring, exact lineup assignment, waivers, trades (stdlib only) |
| `tests/run.sh` | Offline test suite (no network) |
| `tests/make_fixtures.py` | Regenerates the sanitized synthetic fixtures |
| `tests/fixtures/` | Fixture cases, incl. failure modes |
| `samples/` | Example text, Markdown and JSON reports |

## Requirements

- Bash 4+
- `jq`
- `python3` 3.8+ (standard library only)
- `curl` (not needed with `--offline`)

## Options

Run `./fantasy_manager.sh --help` for the full list. Frequently used:

```
-l, --league-id ID     -u, --username NAME    -w, --week N       -s, --season YYYY
-n, --top N            -f, --format text|json|markdown           -o, --output PATH
    --threshold X          --fairness X       --skip-waivers         --skip-trades
    --locked LIST          --horizon N
    --cache-dir DIR        --cache-ttl SEC    --no-cache             --refresh
    --offline              --fixtures DIR     --config PATH
-q, --quiet            -v, --verbose          --debug                --log-file PATH
```

Configuration precedence: **CLI > environment (`FM_*`) > config file > built-in
defaults**. The config file defaults to `~/.config/fantasy_manager/config.env`
(`key=value` lines, `#` comments) and can be overridden with `--config` or
`FM_CONFIG_FILE`. Duplicate CLI options: the last one wins.

Exit codes: `0` success, `2` usage error, `3` missing dependency, `4` data
error (including "projections unavailable").

## What it does

**Scoring.** Projected stats are scored with the league's own
`scoring_settings`, including custom bonuses. Scoring categories that have no
matching stat in the projection feed are excluded and listed explicitly
(`metadata.scoring.unsupported_keys` and a warning). If the league has no usable
scoring settings, the provider's aggregate (`pts_ppr`) is used and the report
says so. When a league scores team-defense or kicker categories the feed has no
stat for (points-allowed tiers, 50+ yard field goals, misses...), adding up the
remaining categories would undercount those positions unevenly, so DEF and/or K
switch to Sleeper's projected total (default scoring) and the report lists this
under `metadata.scoring.position_fallback`.

**Lineup.** Slots are filled by exact maximum-weight assignment (min-cost
max-flow), not greedy allocation, so overlapping FLEX/SUPER_FLEX/IDP slots are
solved optimally. Ties break on total projection, then fewest changes, then
stable player ordering. Each roster slot is compared by index and reported as
`KEEP`, `START`, `MOVE`, `BENCH` or `EMPTY SLOT` with the projected gain.
Changes below `--threshold` are marked `below_threshold` and repeated under
`lineup.optional_actions` instead of being presented as required moves.
Unavailable players (inactive, retired, suspended, exempt, out, IR, PUP,
doubtful) are never recommended and appear in a separate risk section.

**Locks and week selection.** Players whose game has kicked off are locked:
a locked starter stays in his slot (`LOCKED`) and a locked bench player is never
moved in, so mid-week runs only suggest moves you can still make. Locks come
from Sleeper's game schedule (status per team), live points in the week's
matchups, and `--locked "Name, Name"` for anything else. Without `--week`, once
every game of the current week is final the report moves to the next week.

**Matchup.** Opponent, both projected totals, the differential, live points
and a projected final (actual points for players who have played plus
projections for the rest). Correlation and game script are *not* modelled and
the report says so.

**Multi-week window.** Besides this week, projections for the next `--horizon`
weeks (default 3, `0` = this week only) are fetched and scored the same way.
Waivers, drop choices and trades are judged on optimal lineups across the whole
window, so a player on bye or briefly out keeps his value, stashes can surface,
and a partner's one-week bye no longer looks like a positional need. Lineup
advice is always for this week only.

**Waivers.** Free agents are ranked by incremental roster value — what they add
to the optimal lineup and above positional replacement — not by raw projection.
With a window, each row also shows `window_gain` (gain summed over the window)
and the rest-of-season component of the score uses it; players on bye this week
can appear as stashes.
Each row carries the drop candidate, net gain, starter probability and risk
notes, grouped into priority claims, bench upgrades/stashes, streamers and
avoid. Score components without reliable data (schedule fit, and rest-of-season
value when `--horizon 0`) are omitted, the remaining weights are renormalised, and the omissions are
listed. With FAAB leagues a suggested bid in dollars and percent of remaining
budget is shown; otherwise waiver-priority advice.

**Trades.** Partner rosters are profiled by optimal starting points (averaged
over the window), bench value above replacement, positional scarcity, needs and
surplus. Gains and fairness use the whole window; each package also shows this
week's gain. 1-for-1 and 2-for-1
frameworks are evaluated by re-optimising *both* lineups; a package is only
shown if both teams gain and the exchanged value is within the fairness
tolerance (`--fairness`, default 10%). Core starters are not offered unless the
move materially improves the lineup.

## Data sources and failure handling

- Sleeper read-only API: `https://api.sleeper.app/v1`
- Projections: `https://api.sleeper.app/projections/nfl/<season>/<week>` — this
  endpoint is **not** part of Sleeper's documented API and is treated as an
  unstable dependency behind a single cached provider function.
- Schedule: `https://api.sleeper.com/schedule/nfl/<season_type>/<season>` — also
  undocumented and optional (cached 5 minutes, override with `FM_SCHEDULE_BASE`).
  If it is unavailable or its shape changes, locks fall back to live points, the
  week is not advanced automatically, and the report says so.

Every response is validated for JSON syntax *and* expected shape before use.
HTML error pages, truncated JSON, empty arrays and schema changes are rejected.
Transient HTTP failures (408, 429, 5xx, connection errors) are retried up to
four times with exponential backoff and connect/total timeouts; other 4xx
responses (e.g. a mistyped username) fail immediately. If projections cannot be retrieved, a non-expired cached
copy is used and prominently marked `STALE DATA` in every format; if no usable
copy exists the run fails with exit 4 rather than scoring everyone at zero.

Caches live in `~/.cache/fantasy_manager` (override with `--cache-dir`), are
written atomically under an advisory lock, and use portable mtime handling on
Linux and macOS. Temporary files are created with `mktemp -d` under `umask 077`
and removed by an exit trap. `--offline` runs never read or write the default
cache (so fixture data cannot leak into a live run); pass `--cache-dir`
explicitly to cache fixture runs.

Diagnostics (`ERROR`/`WARN`/`INFO`/`DEBUG`) go to stderr and the optional
`--log-file`; only the report goes to stdout. `--quiet` still prints errors.

## Tests

Fully offline — the suite never touches the network:

```bash
bash tests/run.sh                 # 189 assertions
python3 tests/make_fixtures.py    # regenerate fixtures
```

Covered: PPR and custom scoring, superflex, overlapping flex slots, empty
starter placeholders, null fields, players missing from the database, HTML /
malformed / empty / schema-changed projection responses, simulated HTTP 429 and
500, stale-cache fallback and expiry, no eligible player for a required slot,
missing projections, an already optimal lineup, unequal start/bench counts,
dynasty taxi/reserve rosters, configuration precedence, caching, all three
output formats, logging and encoding checks, plus regressions for bye-week
drop advice, rolling-waiver detection, `Sus` suspensions, `--quiet` errors,
offline cache isolation and non-retried 404s, locked starters and bench
players, week rollover, missing schedule, `--locked`, DEF/K scoring fallback
two-way player attribution, multi-week stashes, bye-week trade
exploitation and `--horizon`. The same suite and shellcheck
run in GitHub Actions on every push.

## Limitations

- Value beyond the `--horizon` window (default this week + 3) is not modelled,
  nor are strength of schedule, correlation or game script. Omitted components
  are disclosed in the report rather than approximated.
- Trade evaluation covers the window only and does not price draft picks.
- The projection feed is unofficial and may change or disappear without notice.
