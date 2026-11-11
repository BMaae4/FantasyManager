# FantasyManager

Weekly decision support for a **Sleeper** fantasy football team. Point it at
your league and it tells you:

- **Lineup:** who to start and bench this week (and who is locked because
  their game has started).
- **Waivers:** which free agents are worth claiming, who to drop, and a FAAB
  bid or waiver-priority advice.
- **Trades:** fair trade ideas with other teams in your league.
- **Trade analyzer:** a grade for any trade you're considering, in your league
  or someone else's.
- **Matchup:** your live score and projected final against this week's
  opponent.

It is **read-only**: it reads public Sleeper data and never changes anything
in your league. It can't set lineups, make claims or send trades.

It runs as a **Windows app**, or from the command line on **Windows, macOS
and Linux**. Both use the same analysis and give the same results.

> Only Sleeper leagues can be loaded. The [any-player trade
> grader](#any-player-trades-another-league) works for trades from any
> platform.

---

## Contents

- [Quick start](#quick-start)
  - [1. Find your league ID and username](#1-find-your-league-id-and-username)
  - [2a. Windows](#2a-windows)
  - [2b. macOS and Linux](#2b-macos-and-linux)
  - [3. Save your league as the default](#3-save-your-league-as-the-default)
- [Using it each week](#using-it-each-week)
- [Reading the report](#reading-the-report)
- [Trade analyzer](#trade-analyzer)
- [Options and configuration](#options-and-configuration)
- [How it works](#how-it-works)
- [Data sources and reliability](#data-sources-and-reliability)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Limitations](#limitations)

---

## Quick start

### 1. Find your league ID and username

You need two things:

- **League ID:** a long number (about 18 digits). On
  [sleeper.com](https://sleeper.com), open your league; the number in the
  address bar after `/leagues/` is the league ID:
  `https://sleeper.com/leagues/`**`1400680781302525952`**`/team`
- **Username:** your Sleeper username (the one you sign in with), not your
  team name.

If you only use the phone app and can't find the league ID, you can look it up
from your username in a browser:

1. Open `https://api.sleeper.app/v1/user/YOUR_USERNAME` and copy the
   `user_id` number.
2. Open `https://api.sleeper.app/v1/user/USER_ID/leagues/nfl/2026` (use the
   current season). Each league in the list has its `name` and `league_id`.

> The built-in defaults point at the author's league. Everyone else needs to
> set their own league ID and username, once, as shown below.

### 2a. Windows

1. **Install Python 3.8 or newer** from
   [python.org](https://www.python.org/downloads/). In the installer, tick
   **"Add python.exe to PATH"**.
2. **Download FantasyManager.** On the GitHub page, click **Code → Download
   ZIP**. Before extracting, right-click the ZIP, choose **Properties**, tick
   **Unblock**, and click **OK**; this avoids Windows security prompts. Then
   extract it anywhere, for example `Documents\FantasyManager`.
3. **Double-click `FantasyManager.cmd`.** The window opens.
4. Type your **league ID** and **username** in the toolbar and press
   **Refresh**.

That's it. With **Remember** ticked (the default), a successful refresh saves
your league, username and horizon, so next time the app opens straight to
your league. Nothing is saved if the refresh fails, so a typo is never
remembered.

Nothing else needs installing: Windows PowerShell 5.1 is built in, and
PowerShell 7 works too. You don't need bash, jq or curl on Windows.

**The window**

- **Toolbar:** league, user, week (leave blank for automatic), horizon (how
  many future weeks count; 3 is a good default), **Remember** (save these as
  your defaults after a successful refresh), **Bypass cache**, **Refresh**,
  and **Open/Save report**.
- **Header:** live score and projected final for your matchup, plus a
  warnings panel when something needs your attention.
- **Tabs:**
  - **Lineup:** colour-coded START / MOVE / BENCH / LOCKED rows, plus
    injuries and availability.
  - **Waivers**
  - **Trades:** suggested trade ideas.
  - **Trade Analyzer:** grade your own trade ideas.
  - **Matchup**
  - **Diagnostics:** where each piece of data came from and how fresh it is.

Refresh runs in the background, so the window stays responsive while data
loads.

**Windows command line** (optional; this produces JSON, and the window is the
readable view):

```powershell
.\FantasyManager.ps1                                   # open the window
.\FantasyManager.ps1 -LeagueId 1234... -Username you   # window for a specific league
.\FantasyManager.ps1 -NoGui -OutFile report.json       # JSON report, no window
.\FantasyManager.ps1 -ReportFile report.json           # open a saved report
Get-Help .\FantasyManager.ps1 -Detailed                # every parameter
```

If PowerShell refuses to run the script, use the `.cmd` launcher or run
`powershell -ExecutionPolicy Bypass -File .\FantasyManager.ps1`.

### 2b. macOS and Linux

Requirements: **Bash 4+**, **jq**, **Python 3.8+** (standard library only) and
**curl**.

```bash
# macOS (Homebrew). macOS ships Bash 3.2, so install a current one:
brew install bash jq python

# Debian / Ubuntu
sudo apt install jq python3 curl

# Fedora
sudo dnf install jq python3 curl
```

Then:

```bash
git clone https://github.com/BMaae4/FantasyManager.git
cd FantasyManager
./fantasy_manager.sh --league-id 1234567890123456789 --username yourname
```

You get a text report in the terminal. `--format markdown` or `--format json`
give other formats, and `--output report.md` writes the report to a file.

### 3. Save your league as the default

On Windows the app's **Remember** box does this for you. On macOS and Linux,
or to set more options, create a small config file so plain
`./fantasy_manager.sh` always loads your league:

```ini
# config.env
league_id=1234567890123456789
username=yourname
```

| System | File location | Create it with |
| --- | --- | --- |
| Windows | `%APPDATA%\fantasy_manager\config.env` | In PowerShell: `mkdir -Force "$env:APPDATA\fantasy_manager"; notepad "$env:APPDATA\fantasy_manager\config.env"` |
| macOS / Linux | `~/.config/fantasy_manager/config.env` | `mkdir -p ~/.config/fantasy_manager && nano ~/.config/fantasy_manager/config.env` |

The file holds `key=value` lines, and lines starting with `#` are comments.
Spaces around `=`, quotes and Windows line endings are all fine. Any setting
in [the table below](#settings) can go here, for example `horizon=2` or
`top_n=15`. **Remember** updates only `league_id`, `username` and `horizon`,
and leaves anything else you've added in place. The Windows app and the
command line share the same file.

---

## Using it each week

| When | What to look at |
| --- | --- |
| **Tuesday / Wednesday** (once Monday night's game is final) | The report moves on to the new week by itself. Check **Waivers**: priority claims, suggested drops, and FAAB bids or priority advice. Check **Trades** for trade ideas. |
| **Thursday – Sunday** | **Lineup**: make the START/BENCH moves. Players whose game has started are shown as LOCKED and never moved, so mid-week runs only suggest moves you can still make. Check the risk list for injuries. |
| **During games** | **Matchup**: live score plus the projected final for both teams. |
| **Any time** | **Trade Analyzer**: grade a trade you're thinking about, or one a friend asks about. |

Data is cached, so running it often is quick. Use **Bypass cache** (or
`--refresh`) to force fresh data, for example right after injury news.

## Reading the report

The [`samples/`](samples/) folder has a full example in each format
([text](samples/sample-report.txt), [Markdown](samples/sample-report.md),
[JSON](samples/sample-report.json)) and an example of the [trade
analyzer](samples/sample-trades.txt), all generated from the synthetic test
league.

- **Warnings** come first, and say when something affects the advice: stale
  data, scoring rules the projections can't cover, or a missing schedule.
- **Lineup** shows the current and optimal projected points, then each slot's
  current and recommended player with an action:
  - **KEEP:** leave as is.
  - **START:** put this player in.
  - **MOVE:** shift between slots.
  - **BENCH:** take this player out.
  - **EMPTY SLOT:** nobody available can fill it.
  - **LOCKED:** game already started.

  Moves worth less than `--threshold` points are marked optional.
- **Waivers** list free agents in groups: **priority claims**, **bench
  upgrades / stashes**, **streamers** (QB/TE/K/DEF) and **avoid**. The
  columns:
  - **proj:** this week's projection.
  - **net:** how much your best lineup improves this week after the
    suggested drop.
  - **win:** the gain over the whole window (this week plus the horizon).
  - **score:** the ranking.
  - **drop:** who to let go.
- **Trades** list your needs and surplus, then trade ideas that improve
  *both* lineups and are within the fairness tolerance.
- **Diagnostics** show where each piece of data came from (network, cache or
  stale cache) and how old it is.

All projections come from Sleeper's projection feed, scored with your league's
settings.

---

## Trade analyzer

Three ways to grade a trade. All of them use the same **A+ to F** scale,
based on projected points gained per week across the window (this week plus
`--horizon`, default 3 more):

| Grade | Points gained per week | Grade | Points gained per week |
| --- | --- | --- | --- |
| A+ | 4 or more | C+ | 0.25 |
| A | 3 | C | about even (±0.25) |
| A- | 2.25 | C- | -0.5 |
| B+ | 1.5 | D+ | -1 |
| B | 1 | D | -1.5 |
| B- | 0.5 | F | worse than -1.5 |

Each result also gives the other side's grade, the **chance they accept**
(likely, possible or unlikely), a one-line verdict, notes and warnings.

In the Windows app, all of this is on the **Trade Analyzer** tab, point and
click.

### Your trades (your league)

```bash
./fantasy_manager.sh --trade "Josh Allen for Kenneth Walker III"
./fantasy_manager.sh --trade "Jared Goff, Devaughn Vele for Jameson Williams; Aaron Jones for Rachaad White"
```

- Name the players you give, then `for`, then the players you get.
- Players can be given as full names, unique parts of names (`Jacobs`), or
  Sleeper ids (`id:4984`). `;` separates several trades.
- The other team is worked out from who owns the players you get.
- Both teams' best starting lineups are compared before and after, week by
  week, using their real rosters. Roster limits apply: a team that ends up
  over the limit drops its cheapest player, and the result says who.
- The result shows how many weeks each player would start, a week-by-week
  breakdown, and notes on consolidation, open roster spots and drops. It
  flags injuries, byes and players who have already played this week.

### Trades between two other teams (your league)

The same `--trade` works when you're not involved, for example to judge a trade
two leaguemates made:

```bash
./fantasy_manager.sh --trade "Josh Jacobs for Garrett Wilson"
```

Both teams are graded and the report uses their team names. In the app,
choose **Team A** and **Team B** in **My league** mode.

### Any-player trades (another league)

For a trade outside your league, such as a friend's offer on another platform,
`--value-trade` grades any players against any players. No rosters are needed:

```bash
./fantasy_manager.sh --value-trade "Bijan Robinson for Ja'Marr Chase, Jaylen Waddle" --scoring half --teams 10
```

- **Value:** each player is valued by projected points **above a
  replacement-level starter** across the window. Replacement level is the Nth
  best player at the position in a league of `--teams` (default 12) with a
  standard lineup: 1 QB, 2 RB, 2 WR, 1 TE, 1 FLEX, K, DEF. A week with no
  projection (bye or injury) counts as zero.
- **Scoring:** `--scoring ppr` (default), `half`, `std`, or `league` for your
  own league's rules.
- **Sides:** side A gives the players before `for`, side B gives the rest.
  One side's gain is the other's loss.
- **Notes:** the report points out when the side getting fewer players gets
  the best one (which matters more in deep leagues), roster spots that need
  clearing, and throw-ins at or below replacement.
- **Limits:** it can't see either team's roster, so it doesn't know needs or
  depth, and it says so.
- **Names:** any player can be named, including free agents. Add a team or
  position to pick between players with the same name (`Josh Allen BUF`).

In the app, choose **Any players**, set the scoring and league size, search
by name, team or position, and click players onto each side.

---

## Options and configuration

Run `./fantasy_manager.sh --help` for the full list. The most useful options:

```
-l, --league-id ID     -u, --username NAME    -w, --week N       -s, --season YYYY
-n, --top N            -f, --format text|json|markdown           -o, --output PATH
    --horizon N            --threshold X      --fairness X           --locked LIST
    --trade TEXT           --value-trade TEXT --scoring FMT          --teams N
    --skip-waivers         --skip-trades
    --cache-dir DIR        --cache-ttl SEC    --no-cache             --refresh
    --offline              --fixtures DIR     --config PATH
-q, --quiet            -v, --verbose          --debug                --log-file PATH
```

### Settings

Every setting can come from the command line, an environment variable or the
config file. **Command line > environment variable > config file > built-in
default.**

| Setting | Command line | PowerShell | Config key / env var | Default |
| --- | --- | --- | --- | --- |
| League | `--league-id` | `-LeagueId` | `league_id` / `FM_LEAGUE_ID` | author's league |
| User | `--username` | `-Username` | `username` / `FM_USERNAME` | author |
| Week | `--week` | `-Week` | `week` / `FM_WEEK` | current week (next week once it's over) |
| Season | `--season` | `-Season` | `season` / `FM_SEASON` | current season |
| Season type | `--season-type` | `-SeasonType` | `season_type` / `FM_SEASON_TYPE` | `regular` |
| Future weeks counted | `--horizon` | `-Horizon` | `horizon` / `FM_HORIZON` | `3` (0-6) |
| Rows per section | `--top` | `-Top` | `top_n` / `FM_TOP_N` | `10` |
| Ignore lineup moves smaller than | `--threshold` | `-Threshold` | `threshold` / `FM_THRESHOLD` | `0.5` points |
| Trade fairness tolerance | `--fairness` | `-Fairness` | `fairness` / `FM_FAIRNESS` | `0.10` |
| Treat as locked | `--locked "A, B"` | `-Locked` | `locked` / `FM_LOCKED` | none |
| Grade league trades | `--trade` | `-Trade` | `trade` / `FM_TRADE` | none |
| Grade any-player trades | `--value-trade` | `-ValueTrade` | `value_trade` / `FM_VALUE_TRADE` | none |
| Any-player scoring | `--scoring` | `-Scoring` | `scoring` / `FM_SCORING` | `ppr` |
| Any-player league size | `--teams` | `-Teams` | `teams` / `FM_TEAMS` | `12` (4-32) |
| Report format | `--format` | (JSON only) | `format` / `FM_FORMAT` | `text` |
| Write report to | `--output` | `-OutFile` | `output` / `FM_OUTPUT` | screen |
| Cache folder | `--cache-dir` | `-CacheDir` | `cache_dir` / `FM_CACHE_DIR` | see below |
| Projection cache time | `--cache-ttl` | `-CacheTtl` | `projections_ttl` / `FM_PROJECTIONS_TTL` | `21600` s (6 h) |
| Diagnostics level | `-q` / `-v` / `--debug` | `-Quiet` / `-DebugLog` | `log_level` / `FM_LOG_LEVEL` | `INFO` |
| Diagnostics log file | `--log-file` | `-LogFile` | `log_file` / `FM_LOG_FILE` | none |
| Python to use (Windows) | | `-Python` | `python` / `FM_PYTHON` | auto-detected |
| Config file | `--config` | `-Config` | `FM_CONFIG_FILE` | see [step 3](#3-save-your-league-as-the-default) |

Caches live in `~/.cache/fantasy_manager` on macOS/Linux and
`%LOCALAPPDATA%\fantasy_manager` on Windows. Config keys may also be written
with the `FM_` prefix (`FM_LEAGUE_ID=...`).

**Exit codes:** `0` success, `2` usage error (bad option or value), `3`
missing dependency, `4` data error (league or user not found, projections
unavailable).

---

## How it works

**Scoring.** Projected stats are scored with your league's own
`scoring_settings`, including custom bonuses. Scoring categories with no
matching stat in the projection feed are excluded and listed in a warning. If
a league scores team-defense or kicker categories the feed lacks
(points-allowed tiers, 50+ yard field goals, misses...), adding up the rest
would undercount those positions unevenly. So DEF and/or K use Sleeper's
projected total instead, and the report says so.

**Lineup.** Slots are filled by an exact optimisation (min-cost max-flow), not
a greedy pass, so overlapping FLEX / SUPER_FLEX / IDP slots are solved
optimally. Ties break on total projection, then fewest changes. Unavailable
players (inactive, suspended, out, IR, PUP, doubtful) are never recommended
and appear in the risk list instead.

**Locks and week selection.** Players whose game has kicked off are locked:
a locked starter stays put and a locked bench player is never moved in. Locks
come from Sleeper's game schedule, live points in the week's matchups, and
`--locked "Name, Name"` for anything else. Without `--week`, once every game
of the current week is final the report moves to the next week.

**Matchup.** Opponent, both projected totals, live points and a projected
final (actual points for players who have played plus projections for the
rest). Correlation and game script are not modelled.

**Multi-week window.** Besides this week, projections for the next `--horizon`
weeks are fetched and scored the same way. Waivers, drops and trades are
judged on best lineups across the whole window. So a player on bye or briefly
out keeps his value, stashes can show up, and a partner's one-week bye doesn't
look like a long-term need. Lineup advice is always for this week only.

**Waivers.** Free agents are ranked by what they add to your best lineup, not
by raw projection. The ranking blends roster improvement, rest-of-window
value, depth-chart opportunity and recent add trends. Components without
reliable data are left out, the remaining weights are rescaled, and the
report lists what was left out. A free agent whose game this week has already
started is judged on next week, since that is when a claim pays off. FAAB
leagues get a suggested bid; other leagues get waiver-priority advice.

**Suggested trades.** Each team is profiled by its best starting points
(averaged over the window), its bench above replacement, and its needs and
surplus. 1-for-1 and 2-for-1 ideas are tested by re-optimising *both* lineups.
An idea is only shown if both teams gain and the value exchanged is within the
fairness tolerance (`--fairness`, default 10%). Core starters are only offered
when the move clearly improves your lineup.

---

## Data sources and reliability

- Sleeper's read-only API: `https://api.sleeper.app/v1`
- Projections: `https://api.sleeper.app/projections/nfl/<season>/<week>`. This
  is **not** part of Sleeper's documented API and could change without notice.
- Game schedule: `https://api.sleeper.com/schedule/nfl/<season_type>/<season>`.
  This is also undocumented and optional. If it's unavailable, locks fall back
  to live points, the week isn't advanced automatically, and the report says
  so.

**Validation and retries.** Every response is checked for valid JSON *and* the
expected shape before use. HTML error pages, truncated data and empty
responses are rejected. Temporary failures (timeouts, 429, 5xx) are retried
with backoff; a 404 (for example a mistyped username) fails straight away.

**Stale data.** If projections can't be fetched, a recent cached copy is used
and marked **STALE DATA** in the report. If there is no usable copy, the run
stops with exit code 4 rather than ranking everyone at zero.

**Caching.** Caches are written atomically. Runs with `--offline` (test data)
never touch the normal cache.

**Output.** Diagnostics go to stderr (and `--log-file`); only the report goes
to stdout.

---

## Troubleshooting

| Message | What to do |
| --- | --- |
| `Sleeper user 'X' could not be resolved. Check --username.` | Use your Sleeper **username**, not your team or display name. Check it at `https://api.sleeper.app/v1/user/X`. |
| `User 'X' (id ...) does not own a roster in league N.` | The league ID and username don't match: you are not in that league, or one of them is still the built-in default. Set both. |
| `League N could not be loaded ... Check the league id.` | The league ID is wrong. It's the long number from the league's sleeper.com address. |
| `No valid projections for season S week W ...` | Sleeper has no projections for that week yet (offseason, or very early in the week), or the feed is down. Try later, or pass `--week`. |
| Warning: `Game schedule unavailable ...` | Locks come from live points only. If the week's games are over, pass `--week N+1`. |
| Warning: `STALE DATA ...` | Sleeper couldn't be reached, so a cached copy was used. The report still works; refresh later. |
| Warning: `N league scoring categories have no matching projection stat ...` | Normal for some custom scoring. Those categories can't be projected; DEF/K switch to Sleeper's own totals. |
| Windows: `Python 3.8+ not found` | Install Python from python.org with **Add python.exe to PATH** ticked, then reopen the app. Or set `-Python C:\path\to\python.exe` or `python=` in the config file. |
| Windows: the window doesn't open, or there is a security prompt | Unblock the ZIP before extracting (see [Windows](#2a-windows)), or run `powershell -ExecutionPolicy Bypass -File .\FantasyManager.ps1` to see any error. |
| macOS: `Bash 4 or newer is required` | `brew install bash`, then open a new terminal (or run `$(brew --prefix)/bin/bash fantasy_manager.sh`). |
| `Missing dependency 'jq'` (or python3, curl) | Install it; the message includes the command for your system. |
| Ambiguous player name in a trade | Use more of the name, add a team or position (`Josh Allen BUF`), or use the Sleeper id (`id:4984`). |

For more detail, run with `--debug` (Windows: `-DebugLog`). Diagnostics then
include the effective configuration and every request.

---

## Development

| Path | Purpose |
| --- | --- |
| `fantasy_manager.sh` | Command line: configuration, fetching, caching, validation, text/Markdown/JSON output |
| `FantasyManager.ps1` / `.cmd` | Windows: the same data layer in PowerShell, the WPF window, and a launcher |
| `lib/fm_analysis.py` | All analysis: scoring, lineup optimisation, waivers, trades, trade grading (standard library only) |
| `lib/fm_io.py` | JSON checks and bundle assembly for the PowerShell front end |
| `tests/run.sh` | Offline test suite (241 checks, no network) |
| `tests/make_fixtures.py` | Generates the synthetic test leagues in `tests/fixtures/` |
| `tests/parity.sh` | Runs every fixture through both front ends and compares the reports (needs `pwsh`) |
| `tests/windows.ps1`, `tests/make_expected.sh`, `tests/compare_reports.py` | Windows checks, including a GUI smoke test |
| `samples/` | Example reports generated from the test league |

```bash
bash tests/run.sh                 # offline suite
python3 tests/make_fixtures.py    # regenerate fixtures
bash tests/parity.sh              # bash vs PowerShell, every fixture
```

GitHub Actions runs shellcheck, the offline suite and the parity check on
every push. A Windows job then runs `FantasyManager.ps1` under Windows
PowerShell 5.1 and PowerShell 7. It compares every fixture against the bash
reports, checks validation, caching and config files, and builds the window
from saved reports.

The suite covers:

- PPR and custom scoring, superflex and overlapping flex slots.
- Dynasty taxi/reserve rosters, null fields and players missing from the
  database.
- Bad responses (HTML, malformed or empty data, schema changes), simulated
  429/500 errors, and stale-cache fallback.
- Locks, week rollover, the multi-week window, waivers and suggested trades.
- Every trade-analyzer mode and error case.
- All output formats, config precedence and config-file parsing.

When changing behaviour, update the version in both `fantasy_manager.sh` and
`FantasyManager.ps1`, and add a [CHANGELOG](CHANGELOG.md) entry.

## Limitations

- Sleeper leagues only (the any-player grader works for any platform).
- Value beyond the window (this week plus `--horizon`) isn't modelled, and
  neither are strength of schedule, correlation or game script. What's left
  out is disclosed in the report rather than guessed.
- Trades are judged over the window only, and draft picks aren't priced.
- The projection and schedule feeds are unofficial and may change or
  disappear without notice.
