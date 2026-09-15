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
says so.

**Lineup.** Slots are filled by exact maximum-weight assignment (min-cost
max-flow), not greedy allocation, so overlapping FLEX/SUPER_FLEX/IDP slots are
solved optimally. Ties break on total projection, then fewest changes, then
stable player ordering. Each roster slot is compared by index and reported as
`KEEP`, `START`, `MOVE`, `BENCH` or `EMPTY SLOT` with the projected gain.
Changes below `--threshold` are marked `below_threshold` and repeated under
`lineup.optional_actions` instead of being presented as required moves.
Unavailable players (inactive, retired, suspended, exempt, out, IR, PUP,
doubtful) are never recommended and appear in a separate risk section.

**Matchup.** Opponent, both projected totals, the differential and live points
where the week has started. Correlation and game script are *not* modelled and
the report says so.

**Waivers.** Free agents are ranked by incremental roster value — what they add
to the optimal lineup and above positional replacement — not by raw projection.
Each row carries the drop candidate, net gain, starter probability and risk
notes, grouped into priority claims, bench upgrades/stashes, streamers and
avoid. Score components without reliable data (rest-of-season value, schedule
fit) are omitted, the remaining weights are renormalised, and the omissions are
listed. With FAAB leagues a suggested bid in dollars and percent of remaining
budget is shown; otherwise waiver-priority advice.

**Trades.** Partner rosters are profiled by optimal starting points, bench value
above replacement, positional scarcity, needs and surplus. 1-for-1 and 2-for-1
frameworks are evaluated by re-optimising *both* lineups; a package is only
shown if both teams gain and the exchanged value is within the fairness
tolerance (`--fairness`, default 10%). Core starters are not offered unless the
move materially improves the lineup.

## Data sources and failure handling

- Sleeper read-only API: `https://api.sleeper.app/v1`
- Projections: `https://api.sleeper.app/projections/nfl/<season>/<week>` — this
  endpoint is **not** part of Sleeper's documented API and is treated as an
  unstable dependency behind a single cached provider function.

Every response is validated for JSON syntax *and* expected shape before use.
HTML error pages, truncated JSON, empty arrays and schema changes are rejected.
Transient HTTP failures (408, 429, 5xx, connection errors) are retried with
connect/total timeouts. If projections cannot be retrieved, a non-expired cached
copy is used and prominently marked `STALE DATA` in every format; if no usable
copy exists the run fails with exit 4 rather than scoring everyone at zero.

Caches live in `~/.cache/fantasy_manager` (override with `--cache-dir`), are
written atomically under an advisory lock, and use portable mtime handling on
Linux and macOS. Temporary files are created with `mktemp -d` under `umask 077`
and removed by an exit trap.

Diagnostics (`ERROR`/`WARN`/`INFO`/`DEBUG`) go to stderr and the optional
`--log-file`; only the report goes to stdout.

## Tests

Fully offline — the suite never touches the network:

```bash
bash tests/run.sh                 # 135 assertions
python3 tests/make_fixtures.py    # regenerate fixtures
```

Covered: PPR and custom scoring, superflex, overlapping flex slots, empty
starter placeholders, null fields, players missing from the database, HTML /
malformed / empty / schema-changed projection responses, simulated HTTP 429 and
500, stale-cache fallback and expiry, no eligible player for a required slot,
missing projections, an already optimal lineup, unequal start/bench counts,
dynasty taxi/reserve rosters, configuration precedence, caching, all three
output formats, logging and encoding checks.

## Limitations

- Weekly projections only: no rest-of-season value, strength of schedule,
  correlation or game-script modelling. Omitted components are disclosed in the
  report rather than approximated.
- Trade evaluation is single-week and does not price draft picks.
- The projection feed is unofficial and may change or disappear without notice.
