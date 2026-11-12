# Fantasy Manager - Test League - Week 5

- Season: 2025 (regular)
- Manager: TestManager - Team: Test Titans
- Generated: 2026-11-11T20:19:31Z by fantasy_manager 2.12.0
- Scoring: league scoring_settings (source: league.scoring_settings x projected stats)
- Projections: fixture - `https://api.sleeper.app/projections/nfl/2025/5?season_type=regular&order_by=pts_ppr` - 62 records

> Unsupported scoring keys (no matching projection stat): fum_lost, rec_td

## Warnings

- 2 league scoring categories have no matching projection stat: fum_lost, rec_td. They are excluded.
- Waiver score components omitted (no reliable data): schedule_fit. Remaining weights renormalised.

## Lineup

| Metric | Points |
| --- | ---: |
| Current | 96 |
| Optimal | 109 |
| Gain | 13 |

| Slot | Current | Recommended | Action | Gain |
| --- | --- | --- | --- | ---: |
| QB | Quinn Alpha (QB/AAA) | Quinn Alpha (QB/AAA) | KEEP | 0 |
| RB | Ryan Alpha (RB/AAA) | Ryan Alpha (RB/AAA) | KEEP | 0 |
| RB | Ryan Bravo (RB/BBB) | Ryan Charlie (RB/CCC) | START | 2 |
| WR | Wes Alpha (WR/AAA) | Wes Alpha (WR/AAA) | KEEP | 0 |
| WR | Wes Bravo (WR/BBB) | Wes Charlie (WR/CCC) | START | 5 |
| TE | Tom Alpha (TE/AAA) | Tom Alpha (TE/AAA) | KEEP | 0 |
| FLEX | Tom Bravo (TE/BBB) | Ryan Echo (RB/EEE) | START | 6 |
| K | Kai Alpha (K/AAA) | Kai Alpha (K/AAA) | KEEP | 0 |
| DEF | Alpha Defense (DEF/AAA) | Alpha Defense (DEF/AAA) | KEEP | 0 |

## Matchup

| Team | Projected (current lineup) | Live points |
| --- | ---: | ---: |
| Test Titans | 96 | 0 |
| Team 2 | 100.7 | 0 |

Differential: -4.7

Projected final (live + remaining): 96 vs 100.7

| Win probability | Current lineup | Recommended lineup |
| --- | ---: | ---: |
| 10000 simulations | 38.2% | 69.2% |

Likely range (10th-90th percentile): you 94-125, them 86-116. Score spreads: this season's projection misses for QB, RB, TE, WR; typical spreads for the rest.

> Projection-only optimisation: correlation, game script and opponent defensive matchups are not modelled.

## Projection sources

Sleeper vs ESPN, week 5 (PPR points). Using Sleeper's projections (--projections blend for a 50/50 consensus). Matched 57 players (5 not matched); typical gap 0.8 points.

| Player | Pos | Team | Where | Sleeper | ESPN | Difference |
| --- | --- | --- | --- | ---: | ---: | ---: |
| Wes Alpha | WR | AAA | your starter | 15 | 8 | -7 |
| Free Run One | RB | EEE | free agent | 12 | 18 | +6 |

## Waivers

- Waiver type: FAAB (budget 100, remaining 80.0)
- Weights: add_trend 11%, opportunity 17%, rest_of_season_value 28%, roster_improvement 44%
- Window: weeks 5, 6, 7, 8
- Omitted components: schedule_fit

### Priority claims

| Player | Pos | Team | Proj | Net gain | Window gain | Score | Bid (est) | Drop |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| Free Wide One | WR | EEE | 16.5 | 4.5 | 18 | 1 | $18 (22%) | Wes Delta |
| Free Kick One | K | HHH | 8.5 | 1.5 | 6 | 0.4 | $6 (8%) | Wes Delta |
| Hotel Defense | DEF | HHH | 7.5 | 1.5 | 6 | 0.4 | $6 (8%) | Wes Delta |
| Free Tight One | TE | GGG | 9 | 1 | 4 | 0.3 | $4 (5%) | Wes Delta |

### Bench upgrades / stashes

| Player | Pos | Team | Proj | Net gain | Window gain | Score | Bid (est) | Drop |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| Free Hurt One | WR | EEE | 15 | 0 | 9 | 0.3 | $9 (11%) | Wes Delta |

### Streamers

| Player | Pos | Team | Proj | Net gain | Window gain | Score | Bid (est) | Drop |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| _(none)_ | | | | | | | | |

### Avoid

| Player | Pos | Team | Proj | Net gain | Window gain | Score | Bid (est) | Drop |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| Free Retired One | RB | FFF | 14 | 0 | 0 | 0.2 | n/a | n/a |

## Trades

- My needs: TE
- My surplus: Quinn Bravo, Ryan Bravo, Wes Bravo, Tom Bravo, Ryan Delta

### Team 2

- Needs: RB

| Give | Get | My gain (window) | Their gain (window) | My gain this week | Fairness gap |
| --- | --- | ---: | ---: | ---: | ---: |
| Ryan Bravo | Team2 TE1 | 8.8 | 10 | 2.2 | 3.2 |

## Opportunity

Usage trends, weeks 1, 3, 4 (Sleeper stats: 3 wk).

### Breakout watch (free agents)

| Player | Pos | Team | Snaps | Targets + carries |
| --- | --- | --- | --- | --- |
| Free Run Two | RB | FFF | 25% -> 57% | 5 -> 13 |

### Your players losing role

| Player | Pos | Team | Snaps | Targets + carries |
| --- | --- | --- | --- | --- |
| Wes Bravo | WR | BBB | 89% -> 52% | 8 -> 4.5 |

## History

Projected vs actual points, weeks 1-4, league scoring. 0 projections recorded before kickoff, 237 fetched afterwards.

| Position | Player-weeks | Avg miss | Bias | Within 5 |
| --- | ---: | ---: | ---: | ---: |
| DEF | 19 | 2.5 | -0.2 | 100% |
| K | 19 | 1.8 | -0.3 | 100% |
| QB | 35 | 3.1 | +0.9 | 86% |
| RB | 65 | 3.9 | 0 | 65% |
| TE | 35 | 2.2 | -0.1 | 100% |
| WR | 64 | 3.4 | -0.3 | 73% |
| ALL | 237 | 3.1 | 0 | 81% |

> No stats feed for week 2: only rostered players have results there.

### Your roster: recent form

| Player | Pos | GP | Avg | Proj | Beat | Weekly (actual) |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Quinn Alpha | QB | 4 | 18.3 | 18.3 | 2/4 | 23.3 / 15.8 / 14.5 / 19.6 |
| Wes Charlie | WR | 4 | 16 | 13.9 | 3/4 | 11.6 / 16.7 / 15.2 / 20.3 |
| Ryan Alpha | RB | 4 | 15.4 | 16 | 2/4 | 12.3 / 14.4 / 16 / 18.8 |
| Quinn Bravo | QB | 4 | 14.7 | 12.1 | 4/4 | 12.3 / 14.1 / 15.4 / 17.2 |
| Wes Alpha | WR | 4 | 13.3 | 15 | 1/4 | 12.3 / 10.2 / 8.7 / 21.8 |
| Ryan Charlie | RB | 4 | 12.6 | 13.3 | 2/4 | 17 / 11.8 / 13.4 / 8.2 |
| Ryan Echo | RB | 4 | 11.5 | 11.9 | 2/4 | 15.7 / 17.7 / 5.3 / 7.3 |
| Ryan Bravo | RB | 4 | 9 | 11 | 1/4 | 5.2 / 10.3 / 7.8 / 12.9 |
| Wes Bravo | WR | 4 | 7.8 | 10.6 | 1/4 | 14 / 9 / 5 / 3 |
| Tom Alpha | TE | 4 | 7.1 | 7.9 | 1/4 | 3.9 / 7.5 / 6.4 / 10.6 |
| Kai Alpha | K | 4 | 6.7 | 6.8 | 2/4 | 8.2 / 7.3 / 6.4 / 5.1 |
| Wes Delta | WR | 4 | 6.1 | 3.5 | 3/4 | 6.6 / 8.1 / 9.7 / 0 |
| Alpha Defense | DEF | 4 | 5.2 | 6 | 1/4 | 9.7 / 3.1 / 2 / 5.9 |
| Ryan Delta | RB | 4 | 4.4 | 4 | 2/4 | 0 / 0 / 9.9 / 7.5 |
| Tom Bravo | TE | 4 | 4.2 | 6 | 0/4 | 2.4 / 3.8 / 4.9 / 5.8 |

## Diagnostics

| Source | Origin | Cache age | Records | Note |
| --- | --- | --- | ---: | --- |
| state | fixture | 0m | 4 | ok |
| schedule | fixture | 0m | 8 | ok |
| league | fixture | 0m | 9 | ok |
| rosters | fixture | 0m | 4 | ok |
| users | fixture | 0m | 4 | ok |
| matchups | fixture | 0m | 4 | ok |
| user | fixture | 0m | 3 | ok |
| players | fixture | 0m | 62 | ok |
| projections | fixture | 0m | 62 | ok |
| projections_w6 | fixture | 0m | 62 | ok |
| projections_w7 | fixture | 0m | 62 | ok |
| projections_w8 | fixture | 0m | 62 | ok |
| trending_add | fixture | 0m | 3 | ok |
| transactions | fixture | 0m | 1 | ok |
| espn | fixture | 0m | 1 | ok |
| history | fixture | n/a | 4 | weeks 1-4; 0 stored, 4 fetched; no stats feed for week 2 (rostered players only) |
| nflverse_stats | unavailable | n/a | n/a | fetch or validation failed |
| nflverse_snaps | unavailable | n/a | n/a | fetch or validation failed |

> Read-only tool: it cannot submit lineups, waiver claims or trades.
> Projections are advisory and do not model correlation or game script.
