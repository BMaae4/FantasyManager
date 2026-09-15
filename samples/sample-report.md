# Fantasy Manager - Test League - Week 5

- Season: 2025 (regular)
- Manager: MaTrasaMaae - Team: Trasa Titans
- Generated: 2026-09-14T22:05:01Z by fantasy_manager 2.0.0
- Scoring: league scoring_settings (source: league.scoring_settings x projected stats)
- Projections: cache - `https://api.sleeper.app/projections/nfl/2025/5?season_type=regular&order_by=pts_ppr` - 62 records

> Unsupported scoring keys (no matching projection stat): fum_lost, rec_td

## Warnings

- 2 league scoring categories have no matching projection stat and are excluded: fum_lost, rec_td
- Waiver score components omitted (no reliable data): rest_of_season_value, schedule_fit. Remaining weights renormalised.

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
| Trasa Titans | 96 | 0 |
| Team 2 | 100.7 | 0 |

Differential: -4.7

> Projection-only optimisation: correlation, game script and opponent defensive matchups are not modelled.

## Waivers

- Waiver type: FAAB (budget 100, remaining 80)
- Weights: add_trend 15%, opportunity 23%, roster_improvement 62%
- Omitted components: rest_of_season_value, schedule_fit

### Priority claims

| Player | Pos | Team | Proj | Net gain | Score | Bid (est) | Drop |
| --- | --- | --- | ---: | ---: | ---: | --- | --- |
| Free Wide One | WR | EEE | 16.5 | 4.5 | 1 | $18 (22%) | Wes Delta |
| Free Kick One | K | HHH | 8.5 | 1.5 | 0.4 | $6 (8%) | Wes Delta |
| Hotel Defense | DEF | HHH | 7.5 | 1.5 | 0.4 | $6 (8%) | Wes Delta |
| Free Tight One | TE | GGG | 9 | 1 | 0.4 | $4 (5%) | Wes Delta |

### Bench upgrades / stashes

| Player | Pos | Team | Proj | Net gain | Score | Bid (est) | Drop |
| --- | --- | --- | ---: | ---: | ---: | --- | --- |
| _(none)_ | | | | | | | |

### Streamers

| Player | Pos | Team | Proj | Net gain | Score | Bid (est) | Drop |
| --- | --- | --- | ---: | ---: | ---: | --- | --- |
| _(none)_ | | | | | | | |

### Avoid

| Player | Pos | Team | Proj | Net gain | Score | Bid (est) | Drop |
| --- | --- | --- | ---: | ---: | ---: | --- | --- |
| Free Hurt One | WR | EEE | 15 | 0 | 0.2 | n/a | n/a |
| Free Retired One | RB | FFF | 14 | 0 | 0.2 | n/a | n/a |

## Trades

- My needs: TE
- My surplus: Quinn Bravo, Ryan Bravo, Wes Bravo, Tom Bravo, Ryan Delta

### Team 2

- Needs: RB

| Give | Get | My gain | Their gain | Fairness gap |
| --- | --- | ---: | ---: | ---: |
| Ryan Bravo | Team2 TE1 | 2.2 | 2.5 | 0.8 |

## Diagnostics

| Source | Origin | Cache age | Records | Note |
| --- | --- | --- | ---: | --- |
| state | fixture | 0m | 4 | ok |
| league | fixture | 0m | 9 | ok |
| rosters | fixture | 0m | 4 | ok |
| users | fixture | 0m | 4 | ok |
| matchups | fixture | 0m | 4 | ok |
| user | fixture | 0m | 3 | ok |
| players | cache | 0m | 62 | fresh cache |
| projections | cache | 0m | 62 | fresh cache |
| trending_add | cache | 0m | 3 | fresh cache |
| transactions | fixture | 0m | 1 | ok |

> Read-only tool: it cannot submit lineups, waiver claims or trades.
> Projections are advisory and do not model correlation or game script.
