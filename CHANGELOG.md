# Changelog

All notable changes to `fantasy_manager.sh`.

## 3.4.0

### Added

- **Opponent strength.** Fantasy points each NFL defense has allowed to
  each position this season, in the league's scoring, against the league
  average.
  - Each starter's opponent is rated easy, neutral or tough (text,
    Markdown, JSON `lineup.slots[].matchup` and `opponent_strength`, and
    an **Opponent** column on the Lineup and Waivers tabs).
  - It is the **schedule fit** part of the waiver score, which was left
    out before. Projections are not adjusted by it.
  - Needs three past weeks of results and the game schedule.
- **Playoff odds.** The rest of the regular season simulated 5,000 times
  from the standings, the league's remaining schedule and each team's
  expected score.
  - Every team's chance to make the playoffs, projected wins and average
    seed, plus your chance with a win or a loss this week (text, Markdown,
    JSON `playoffs`, and a **Playoffs** tab in the Windows app).
  - Works for Sleeper and ESPN leagues. Left out, with the reason, after
    the regular season or when the league's schedule can't be read.
- **ESPN leagues use more of ESPN's own data.**
  - ESPN's projections are read through the league, so they are in league
    scoring for every position. The source comparison is in league points,
    and `--projections blend` is a plain average of the two.
  - The waiver add trend comes from ESPN ownership changes instead of
    Sleeper's trending adds (JSON `waivers.trend_source`).
- JSON schema version 2.1.

### Tests

- New fixture `season_outlook` (four weeks of results on a real schedule,
  standings, and pairings through the last regular-season week); the
  `espn_league` fixture gains records, a schedule and ownership changes.

## 3.3.0

### Added

- Auto-refresh in the Windows app: a box on the bottom line refreshes the
  report every 1, 2, 5, 10, 15, 30 or 60 minutes.
  - An automatic refresh uses the cache as usual, saves no defaults and
    shows no dialogs. A failure is reported on the bottom line and the
    report on screen stays.
  - It waits while another job runs or the Trade Analyzer is open.
  - The bottom line shows when the last update was and when the next is
    due.
  - The interval is saved with **Remember** ticked (`auto_refresh=`, in
    minutes), or set with `-AutoRefresh` / `FM_AUTO_REFRESH`.

### Changed

- The dropdown boxes (platform, horizon, team pickers, scoring,
  auto-refresh) match the rest of the window: rounded, with a flat list.

## 3.2.0

A visual pass over the Windows app. The analysis and the reports are
unchanged.

### Changed

- Toolbar: everything fits at the default window size (the Save button was
  cut off). **Open** and **Save** sit on the right, and the status text
  moved to the bottom line.
- Flat tabs, buttons and text boxes; calmer tables with more row spacing,
  right-aligned numbers, and long cells trimmed with a tooltip.
- Lineup: slot names as fantasy sites show them (RB/WR, WR/TE, SFLEX,
  D/ST), an action badge per row, and every slot visible without
  scrolling inside the table.
- Waivers: a badge for the group (Priority, Streamer, Avoid).
- Matchup: a scoreboard with both teams, projected finals, likely ranges
  and a win-probability bar; the header card gets the same bar. Text the
  scoreboard already shows is no longer repeated below it.
- Header line: team, platform, season and when the report was updated. An
  ESPN team is no longer shown twice.
- Trade Analyzer lists no longer scroll sideways.

## 3.1.0

### Added

- A league per platform. Sleeper and ESPN each keep their own league and
  user or team, so switching platform no longer carries the other
  platform's league id across.
  - Config keys `sleeper_league_id`, `sleeper_username`, `espn_league_id`
    and `espn_team` (also as `FM_` variables); `platform` picks which one
    is used.
  - In the Windows app, switching the platform box swaps the league and
    user or team boxes to that platform's saved values, and keeps what was
    typed for the other one.
  - **Remember** saves each platform under its own keys and keeps the
    other platform's.

### Changed

- The plain `league_id`, `username` and `team` keys still work. A plain
  `league_id` in the config file now belongs to the `platform` saved next
  to it and is not used for the other platform. **Remember** replaces the
  plain keys with the per-platform ones.

## 3.0.0

ESPN leagues.

### Added

- **ESPN leagues load natively**: `--platform espn --league-id ID --team
  NAME` (PowerShell `-Platform espn -Team`, config `platform=` and `team=`,
  a platform box in the Windows toolbar).
  - The team is given by name, a unique part of the name, its abbreviation
    or its ESPN team id. An unknown or ambiguous name lists the league's
    teams.
  - The league must be viewable to the public. No ESPN sign-in is used.
- A new module, `lib/fm_espn.py`, converts the league to the form the
  analysis already uses:
  - lineup slots, including RB/WR, WR/TE, FLEX, OP (superflex), IR and IDP
    slots
  - scoring items to projected stats, with a TE-premium style reception
    bonus; an item with no projected stat is left out and listed in a
    warning
  - rosters and current lineups, with players matched by ESPN id, then by
    name; an unmatched rostered player is kept and listed in a warning
  - waiver type and budget, the trade deadline (by date) and the last
    fantasy week
  - the week's box scores for the matchup, live points and past results
- Kickers and team defenses in an ESPN league use ESPN's own projections,
  scored by ESPN with the league's rules, for every window week ESPN
  covers. A week ESPN doesn't cover is listed in a warning.
- JSON: `metadata.platform` and `metadata.scoring.host_scored`. Schema
  version 2.0.

### Removed

- The built-in default league id and username. A league and user (or ESPN
  team) must now be given on the command line, in `FM_*` variables or in
  the config file; without them the run stops with exit code 2 and says
  what to set. The Windows window opens with empty boxes the first time.
- The author's league id and username no longer appear in the code,
  tests, fixtures or samples; the test league uses made-up ones.

### Changed

- The history database keys an ESPN league as `espn:<league id>`; Sleeper
  leagues are unchanged.
- ESPN reports show `ESPN league <id>` and the team in the header instead
  of a manager name.
- The Windows **Remember** box also saves the platform, and the team for an
  ESPN league.
- Reports for Sleeper leagues are unchanged apart from the new JSON fields.

### Tests

- New fixture `espn_league` in ESPN's format, with a player matched by
  name, an ESPN-only player, a scoring item with no stat, a passed trade
  deadline and a week without ESPN kicker and defense projections.
- Checks for the conversion, team lookup, validation and the converter on
  its own, a bash/PowerShell parity case, and Windows checks including the
  window loading an ESPN report.

## 2.12.1

Fixes from the first live run.

### Fixed

- ESPN projections came back without any numbers, so no players were
  compared.
  - The request filter now asks for the week's projections by ESPN's period
    codes, the version that returned them in a live test.
  - Rows from another season are ignored (ESPN can also return last
    season's projection for the same week).
- Recent form counted bye weeks as 0-point games. A week now counts only
  when the player was projected to play or scored, and team byes from the
  schedule are skipped.
- "Losing role" was flagged on a snap-share drop alone, even when targets +
  carries went up. A snap drop now needs touches that didn't rise.

### Tests

- Regression checks for all three, including a decoy last-season ESPN row
  in the fixtures (365 checks).

## 2.12.0

### Added

- A projection provider layer (`lib/fm_providers.py`) with ESPN as a second
  source.
  - ESPN's weekly projections (public fantasy API, PPR) are matched to
    Sleeper players by ESPN id, by name and team, or by team for defenses.
- By default ESPN is only **compared**. A new **Projection sources** section
  (text, Markdown, JSON `projection_sources`, and a **Sources** tab on
  Windows) shows:
  - the number of matched players and the typical gap
  - your players, and free agents projected 8+ points, where the sources are
    4+ points and 30%+ apart
- `--projections blend` (`-Projections blend`, `projections_mode=blend`):
  a 50/50 consensus for every window week ESPN covers.
  - Each league-scored Sleeper projection moves halfway toward ESPN's, as a
    ratio of the PPR totals capped at ±50%.
  - It covers the lineup, matchup, win probability, waivers and league
    trades.
- `--compare espn|none` (`-Compare`, `compare=`; default `espn`).
  `FM_ESPN_BASE` overrides the source.
- If ESPN is unavailable, the section says so. A blend falls back to Sleeper
  with a warning.
- The player database keeps `espn_id`. JSON schema version 1.5.

### Tests

- New fixture `espn_compare` in ESPN's response format, with one name-only
  match. 21 new checks (360 total):
  - matching, disagreements and the typical gap
  - the comparison leaving advice unchanged, and blending (halfway
    projection, lineup total, all window weeks)
  - unavailable ESPN, `--compare none` and validation
  - the ESPN parser on its own: response shapes, D/ST, suffix-insensitive
    names, other stat rows ignored
- Windows GUI check for the Sources tab after a `-Projections blend` run.

## 2.11.0

### Added

- `--horizon ros` (PowerShell `-Horizon ros`, `horizon=ros`, **ROS** in the
  Windows horizon box) values the rest of the fantasy season.
  - The window runs through the league's last playoff week, worked out from
    `playoff_week_start`, `playoff_teams` and `playoff_round_type` (week 17
    if they're missing).
  - Weeks without projections yet shorten the window, and the label says
    from which week.
- Two trade grades: **this week** (the immediate lineup effect) and **the
  window** (per week over the horizon, or the rest of the season with
  `ros`).
  - The overall grade stays the window grade.
  - A note explains when the two disagree.
  - Shown in text, Markdown, JSON `grades` on league and any-player trades,
    and the Windows Trade Analyzer.
- A trade after the league's `trade_deadline` is flagged.
- JSON `metadata.horizon_mode` and `metadata.window_label`; schema version
  1.4.

### Changed

- The Windows Trade Analyzer grades with the report's own horizon,
  including `ros`.

### Tests

- New fixture `rest_of_season` with projections through week 17, a partner
  back on bye this week only, and a passed trade deadline. 18 new checks
  (339 total).
- Windows check for `-Horizon ros`.

## 2.10.0

### Added

- Opportunity trends: snap share and targets + carries per player, earlier
  weeks against the last two (of the last four with usage, byes skipped).
  - **Breakout watch:** free agents whose role is growing (snaps up 15+
    points to 45%+, or targets + carries up 4+ and half again).
  - **Your players losing role:** snaps down 15+ points from 40%+, or
    touches down 4+ and 40%.
  - Waiver rows of breakout players get a "Role growing" note.
  - Shown in text, Markdown, JSON `opportunity` and a new **Trends** tab in
    the Windows app.
- Usage from nflverse when Sleeper's stats feed doesn't cover a week:
  - weekly player stats (targets, carries, target share) and snap counts,
    from nflverse's public GitHub releases (about 5 MB, cached 12 hours)
  - matched by GSIS id, or by name and team (`LA` = `LAR`)
  - stored in the history database, so it's downloaded once per week
  - `FM_NFLVERSE_BASE` overrides the source
- The player database keeps `gsis_id`.
- JSON schema version 1.3.

### Tests

- New fixture `usage_nflverse`: the stats feed is down for every past week,
  and nflverse supplies the usage. 17 new checks (321 total):
  - breakout and decline detection from both sources
  - matching by GSIS id and by name and team code
  - the waiver note
  - nflverse usage persisting in the database, and the download cache
  - text and Markdown output
- Windows GUI check for the Trends tab.

## 2.9.0

### Added

- Win probability. The matchup is simulated 10,000 times, with each
  starter's score spread around the projection.
  - Spreads are by position and wider for bigger projections.
  - They come from this season's projection misses once a position has 30+
    games in the history, and use typical values before that.
  - A player with 3+ games also counts his own boom-or-bust record (blended
    with the position estimate).
  - Players whose game has started count at their current points.
- The report shows:
  - the chance to win with your current lineup and with the recommended one
  - the likely score range for both teams (10th to 90th percentile)
  - which spreads were used
  - swaps that raise the chance by a point or more, even when they project
    lower (for example a volatile back when you're a big underdog)
- In text, Markdown and JSON `matchup.win_probability`. On Windows it is in
  the Matchup tab, and the header shows the win chance.
- Results are reproducible: the same league and week always give the same
  numbers.
- JSON schema version 1.2.

### Tests

- 16 new checks (304 total):
  - the simulated win chance matches the closed-form normal result within
    1.5 points
  - reproducibility and history-based spreads
  - locked players
  - a new `underdog_volatile` fixture where the volatile bench back is the
    suggested swap
  - text and Markdown output
- Windows GUI check for the header.
- `compare_reports.py` allows ±0.01 in simulated numbers, for last-digit
  differences between platforms' math libraries.

## 2.8.0

### Added

- Season history and projection accuracy.
  - Each run saves this week's projections to `history.sqlite` in the cache
    folder before each player's game starts.
  - The first run of a season fills in the past weeks once:
    - the projections for each week
    - the league's own points for every rostered player (from the weekly
      matchups)
    - Sleeper's weekly stats, which add free agents and usage
  - Later runs fetch only new weeks.
  - Parts that failed are retried at most once a day; `--refresh` retries
    them now and refetches last week's results for stat corrections.
- New report section **History** (text, Markdown, JSON `history`, and a
  **History** tab in the Windows app):
  - projection accuracy by position: average miss, bias, spread, and the
    share of games within 5 points
  - recent form for your roster: last four games, average points, average
    projection, games above projection, and weekly scores
- Projections saved before kickoff are preferred over ones fetched
  afterwards, and the report says how many of each were compared.
- Waiver rows show recent form (`form` column, JSON `recent`).
- `--no-history` (`-NoHistory`, `history=0`) and `--history-db PATH`
  (`-HistoryDb`). The database is in memory with `--no-cache` and for
  offline test runs.
- `lib/fm_history.py`: the database and the statistics, standard library
  only.
- JSON schema version 1.1 (adds `history`).

### Tests

- New fixture `season_history` with four past weeks, including a failed
  stats feed for week 2. 32 new checks (288 total):
  - accuracy against an independent calculation
  - league points winning over the stats feed
  - the database across runs, snapshots and `--history-db`
  - `--no-history` and `--no-cache`
  - text and Markdown output
  - the Windows History tab

## 2.7.0

### Changed

- One application for both front ends: `lib/fm_app.py` now does what
  `fantasy_manager.sh` and `FantasyManager.ps1` each did separately:
  - the command line and configuration
  - fetching, retries, caching and the stale-data fallback
  - validation, the run pipeline and the text, Markdown and JSON reports

  Reports, messages and exit codes are unchanged; all 109 recorded
  outputs of 2.6.0 were compared byte for byte.
- `fantasy_manager.sh` is now a small launcher. macOS and Linux need only
  Python 3.8+: no jq, curl or Bash 4 (macOS's built-in Bash 3.2 works).
- `FantasyManager.ps1 -NoGui` maps its parameters onto the same module, and
  the window pre-fills from it, so a setting can no longer behave
  differently on Windows. About 450 lines of duplicated PowerShell are gone.
- Windows: new `-Format text|markdown|json` (JSON stays the `-NoGui`
  default).

### Removed

- `lib/fm_io.py` (its job is now part of `fm_app.py`).

### Tests

- The fake-`curl` test is replaced by a local HTTP server, which checks
  that a 404 is not retried and a 503 is retried three times.
- New checks:
  - `--print-config` precedence
  - running with only `python3` on `PATH`
  - the missing-Python error
  - running `fm_app.py` directly
  - Windows `-Format`

## 2.6.0

### Added

- Windows app: a **Remember** checkbox, ticked by default. After a successful
  refresh it saves the league, username and horizon to `config.env`, so the
  app opens on your league next time.
  - Nothing is saved when the refresh fails, so a typo is never remembered.
  - Other settings and comments in the file are kept, and existing
    `league_id` / `FM_LEAGUE_ID` lines are updated in place.
  - The file is written atomically as UTF-8, and the command line reads the
    same file.
  - Windows CI checks the save round trip under PowerShell 5.1 and 7.

## 2.5.1

### Changed

- README rewritten for new users. It now covers:
  - finding your league ID and username, and step-by-step setup on Windows,
    macOS and Linux
  - saving your league in a config file
  - a weekly routine and how to read the report
  - all three trade-analyzer modes
  - a settings table covering the command line, PowerShell and config keys
  - troubleshooting for the common error messages
- `--trade` help text: works between any two teams, not only your own.
- Sample reports regenerated with every current section, plus a new
  `samples/sample-trades.txt`.

### Fixed

- Config files: values are trimmed, so `key = value`, trailing spaces and
  Windows line endings work in both front ends. Before this, a hand-written
  `league_id = 123` line failed validation.

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

Rewrite against the implementation brief. The hardcoded default league
and username are preserved, so the script still runs with no arguments
(removed in 3.0.0).

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
