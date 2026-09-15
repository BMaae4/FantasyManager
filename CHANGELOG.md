# Changelog

All notable changes to `fantasy_manager.sh`.

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
