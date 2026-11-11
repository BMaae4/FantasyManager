# Changelog

All notable changes to `fantasy_manager.sh`.

## 2.5.0

### Added

- `--trade` now grades trades between any two teams in the league, not just
  your own; results carry `side_a` and use team names in the verdict, notes
  and reports.
- Any-player trade grader: `--value-trade "A, B for C"` (PowerShell
  `-ValueTrade`, `FM_VALUE_TRADE`), e.g. a friend's offer in another league.
  - No rosters needed; any NFL players can be named, including free agents.
  - Players are valued by projected points above a replacement-level starter
    across the window.
  - `--scoring ppr|half|std|league` (default ppr; half and standard are
    derived from PPR and receptions when the feed lacks them) and
    `--teams N` (4-32, default 12) set the replacement levels.
  - The result has grades for both sides, acceptance, a verdict, and per
    player points and value above replacement. Notes cover consolidation,
    roster spots and below-replacement players; injury and bye flags are
    included.
  - Ambiguous names list position and team; adding either narrows the match.
- JSON `value_trades` and `player_pool` (projected players with window points
  in each scoring format).
- Windows app: the Trade Analyzer tab gains a Team A picker (any two teams)
  and an **Any players** mode. That mode has scoring and league-size inputs
  and searchable pick lists for each side.

## 2.4.0

### Added

- Trade analyzer: `--trade "Give A, Give B for Get C"` (PowerShell `-Trade`,
  `FM_TRADE`) grades your own trades.
  - Players can be named in full, by a unique part of the name, or by
    Sleeper id; `;` separates trades, and the partner is inferred from who
    owns the players you get.
  - Both teams' optimal lineups are compared across the window, with roster
    limits enforced by dropping the cheapest player.
  - The result has grades for you and the partner (A+ to F on starting
    points per week), chance of acceptance, a verdict, weekly gains, weeks
    started per player, notes and injury/bye/lock flags.
  - Clear errors for ambiguous or unknown names, one-sided input and
    three-team trades.
- Text and Markdown "Trade analyzer" sections; JSON `custom_trades`.
- JSON `rosters`: every team's active players with this-week and window
  projections.
- Windows app: a **Trade Analyzer** tab with a partner picker, give/get
  lists, a running total and a Grade button. It grades against the loaded
  report's week and window. Refresh and grading share one background runner.

## 2.3.0

### Added

- Windows front end: `FantasyManager.ps1` (Windows PowerShell 5.1 or
  PowerShell 7) with a WPF window.
  - Toolbar: league, user, week, horizon, cache bypass, refresh, open/save
    report.
  - Header: live score and projected final for the matchup.
  - Warnings panel, and tabs for lineup (colour-coded actions), waivers,
    trades, matchup and diagnostics.
  - Refresh runs in a background process so the window stays responsive.
  - `-NoGui` writes the JSON report; `-ReportFile` opens a saved one.
  - `FantasyManager.cmd` launches it without a console or execution-policy
    prompt.
- The PowerShell data layer mirrors the bash script: same options,
  precedence, retries, cache, offline fixtures, locks, rollover and future
  weeks, so both produce identical reports. Only Python is required (no bash,
  jq or curl).
- `lib/fm_io.py`: JSON validation and bundle assembly shared with the
  PowerShell front end. Windows PowerShell 5.1 cannot parse the 5 MB player
  database, so this work happens in Python.
- `fm_analysis.py --in/--out`, so Windows doesn't need text pipes.
- CI: parity of pwsh vs bash on every fixture, plus a Windows job. The
  Windows job runs under PowerShell 5.1 and 7, compares against the bash
  reports, checks CLI validation and caching, and smoke-tests the GUI.
- `.gitattributes` keeps shell and Python files LF and PowerShell files CRLF
  on Windows checkouts.

## 2.2.1

### Fixed

- Once this week's games have kicked off, free agents whose game has started
  scored "net 0" and priority claims came back empty, even though a claim made
  now pays off next week. Such players are now judged on the next window week
  (`evaluated_week`, noted in the row).
- The risk list no longer shows injury tags for players who have already
  played this week, and the locked list leaves out players who were
  unavailable anyway.

## 2.2.0

### Added

- Multi-week window: projections for the next `--horizon` weeks (default 3,
  0-6, `FM_HORIZON`) are fetched, cached and scored like this week's. A missing
  week shortens the window with a warning.
- Waivers fill the previously omitted rest-of-season component from the window,
  show each player's `window_gain`, and can surface stashes (players on bye or
  out this week who project well afterwards). FAAB bids and waiver-priority
  advice use the average gain per window week.
- Drop candidates are chosen by what the roster loses over the window, so
  bye-week starters keep their value without a special rule (`--horizon 0`
  keeps the 2.0.1 protection).
- Trades are judged on optimal lineups across the window; positional needs use
  window-average depth, so a partner's one-week bye is no longer exploited (the
  week 9 "give Josh Allen" suggestion). Packages also report this week's gain.

## 2.1.0

### Added

- Locked players: starters whose game has kicked off are kept in place
  (`LOCKED`) and bench players whose game has started are never moved in, so
  Thursday-Sunday runs only suggest moves that can still be made. Sources: the
  game schedule, live matchup points, and a new `--locked` option.
- Week rollover: without `--week`, the report moves to the next week once every
  game of the current week is final (Sleeper's state keeps the old week until
  midweek). The report says when this happened.
- Matchup "projected final": actual points for players who have played plus
  projections for the rest.
- Optional schedule provider (`FM_SCHEDULE_BASE`, `FM_SCHEDULE_TTL`), validated
  and cached; the run continues with a warning when it is unavailable.

### Fixed

- Team-defense and kicker scores were partial sums when the league scored
  categories the projection feed lacks (points-allowed tiers, 50+ yard field
  goals, misses). Those positions now use Sleeper's projected total.
- Two-way players starting in an offensive slot were counted at their listed
  defensive position, producing needs like "DB" in leagues with no DB slot.
- Trade frameworks now need at least 0.5 projected points for both teams (they
  could show "their gain 0").
- Text columns always keep at least one space (long names ran into the next
  column).

## 2.0.1

### Fixed

- `fantasy_manager.sh` and `tests/run.sh` are committed as executable, so
  `./fantasy_manager.sh` works on a fresh clone (118 of 135 tests failed before).
- The test suite used `--no-waivers`/`--no-trades`; the options are
  `--skip-waivers`/`--skip-trades`.
- `--offline` runs no longer read or write the default cache. Previously a
  fixture run cached the synthetic player database for 24h and the next live
  run used it.
- Waiver drop suggestions no longer target bench players who have no
  projection or are unavailable this week (bye week, Out, suspended). They are
  listed in a warning instead.
- Leagues are treated as FAAB only when `waiver_type` is 2. Sleeper also fills
  in `waiver_budget` on rolling and reverse-standings leagues, which produced
  FAAB bids there. Budget fields are omitted for non-FAAB leagues.
- `--quiet` prints errors again (it suppressed everything, including fatal
  errors).
- Suspensions reported as injury_status `Sus` are blocked from lineups.
- Only 408/429/5xx/connection errors are retried (with backoff); 404s fail
  immediately. Removed `--retry-all-errors`, which needed curl 7.71+.
- Ctrl-C/SIGTERM now stop the run instead of continuing after cleanup.
- Replacement levels share FLEX-type slots between their eligible positions
  instead of counting each as a full extra starter for every position.

### Added

- Regression fixtures (`bye_week_bench`, `rolling_waivers`,
  `suspended_player`) and 16 regression assertions (151 total).
- GitHub Actions workflow running shellcheck and the offline suite.

## 2.0.0

Rewrite against the implementation brief. The hardcoded defaults
(league `1400680781302525952`, username `MaTrasaMaae`) are preserved, so the
script still runs with no arguments.

### Fixed

- Repaired HTML-contaminated source text: the API base is plain
  `https://api.sleeper.app/v1`, redirections and here-strings are valid shell.
- Option values are validated before shifting, so a trailing `--week` no longer
  consumes the next option or fails silently.
- Failed projection fetches no longer collapse to zero points and silently
  recommend benching the whole roster.
- Lineup selection uses exact maximum-weight assignment instead of greedy
  position-by-position allocation, which mis-filled overlapping flex slots.

### Added

- League-aware scoring from `scoring_settings` applied to raw projected stats,
  with explicit reporting of unsupported scoring categories and the scoring
  source/mode.
- Single cached projection provider interface with schema validation, stale
  cache fallback (prominently marked) and full provenance (URL, source, fetch
  time, cache age, record count).
- Slot-by-slot lineup comparison with `KEEP`/`START`/`MOVE`/`BENCH`/`EMPTY SLOT`
  actions, per-action and total projected gain, and a configurable churn
  threshold that demotes marginal moves to optional.
- Availability filtering (inactive, retired, suspended, exempt, out, IR, PUP,
  doubtful) plus a separate risk section.
- Matchup context: opponent, projected totals, differential and live points.
- Waiver ranking by incremental roster value with replacement advantage, drop
  candidate, starter probability, risk notes, grouped priorities, FAAB bid or
  waiver-priority guidance, and disclosure of omitted score components with
  renormalised weights.
- Trade analysis based on optimal starter points, bench value above
  replacement, scarcity, needs and surplus, producing balanced 1-for-1 and
  2-for-1 frameworks with both teams' lineup impact and depth before/after.
- Structured `ERROR`/`WARN`/`INFO`/`DEBUG` logging on stderr and optional
  `--log-file`; report output stays on stdout. `--quiet`, `--verbose`,
  `--debug`.
- Secure temporary workspace (`mktemp -d`, `umask 077`, cleanup trap), atomic
  cache writes with an advisory lock, and portable file mtime handling for
  Linux and macOS.
- Text, JSON and Markdown renderers plus `--output PATH`; the JSON report is
  stable and machine readable (metadata, warnings, lineup, matchup, waivers,
  trades, diagnostics).
- Configuration precedence: CLI > environment (`FM_*`) > config file >
  built-in defaults, with the effective configuration logged in debug mode.
- Offline mode (`--offline --fixtures DIR`), a synthetic sanitized fixture set
  and a 135-assertion Bash test suite that runs without network access.
- README, changelog and sample text/Markdown/JSON reports.
