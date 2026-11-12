#!/usr/bin/env python3
"""Generate the sanitized offline fixtures used by tests/run.sh.

Everything here is synthetic: fake player ids, fake names, fake teams and
deterministic projected stat lines.  No real Sleeper payloads are committed.

Usage: python3 tests/make_fixtures.py [output_dir]
"""

from __future__ import annotations

import copy
import csv
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "fixtures")

PPR_SCORING = {
    "pass_yd": 0.04,
    "pass_td": 4,
    "pass_int": -2,
    "rush_yd": 0.1,
    "rush_td": 6,
    "rec": 1,
    "rec_yd": 0.1,
    "rec_td": 6,
    "fum_lost": -2,
    "fgm": 3,
    "xpm": 1,
    "sack": 1,
    "def_td": 6,
}

TEAMS = ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG", "HHH"]


def stat_line(position: str, points: float) -> dict:
    """Build a projected stat line that scores exactly `points` under PPR."""
    position = position.upper()
    if position == "QB":
        return {"pass_td": 2, "pass_yd": round((points - 8) / 0.04, 2), "pass_int": 0}
    if position == "RB":
        return {"rush_td": 1, "rec": 3, "rush_yd": round((points - 9) / 0.1, 2)}
    if position == "WR":
        return {"rec": 5, "rec_yd": round((points - 5) / 0.1, 2)}
    if position == "TE":
        return {"rec": 4, "rec_yd": round((points - 4) / 0.1, 2)}
    if position == "K":
        return {"fgm": 1, "xpm": round(points - 3, 2)}
    if position == "DEF":
        return {"sack": round(points, 2), "def_td": 0}
    return {"rec": round(points, 2)}


class Builder:
    def __init__(self) -> None:
        self.players: dict = {}
        self.projections: list = []
        self.counter = 0

    def add(
        self,
        pid: str,
        name: str,
        position: str,
        points,
        team: str = "AAA",
        status: str = "Active",
        injury_status=None,
        active: bool = True,
        depth_chart_order=1,
        extra_stats=None,
        in_db: bool = True,
    ) -> str:
        if in_db:
            self.players[pid] = {
                "player_id": pid,
                "full_name": name,
                "first_name": name.split()[0],
                "last_name": name.split()[-1],
                "position": position,
                "fantasy_positions": [position],
                "team": team,
                "status": status,
                "injury_status": injury_status,
                "injury_notes": None,
                "practice_participation": None,
                "active": active,
                "years_exp": 3,
                "depth_chart_position": position,
                "depth_chart_order": depth_chart_order,
                "news_updated": 1700000000000,
            }
        if points is not None:
            stats = stat_line(position, points)
            stats["pts_ppr"] = points
            if extra_stats:
                stats.update(extra_stats)
            self.projections.append(
                {
                    "player_id": pid,
                    "week": 5,
                    "season": "2025",
                    "season_type": "regular",
                    "company": "synthetic",
                    "stats": stats,
                }
            )
        return pid


def build_base() -> dict:
    b = Builder()

    # --- my roster (roster_id 1) --------------------------------------
    my_players = [
        b.add("qb1", "Quinn Alpha", "QB", 18.0, "AAA"),
        b.add("qb2", "Quinn Bravo", "QB", 12.0, "BBB"),
        b.add("rb1", "Ryan Alpha", "RB", 16.0, "AAA"),
        b.add("rb2", "Ryan Bravo", "RB", 11.0, "BBB"),
        b.add("rb3", "Ryan Charlie", "RB", 13.0, "CCC"),
        b.add("wr1", "Wes Alpha", "WR", 15.0, "AAA"),
        b.add("wr2", "Wes Bravo", "WR", 9.0, "BBB"),
        b.add("wr3", "Wes Charlie", "WR", 14.0, "CCC"),
        b.add("te1", "Tom Alpha", "TE", 8.0, "AAA"),
        b.add("te2", "Tom Bravo", "TE", 6.0, "BBB"),
        b.add("k1", "Kai Alpha", "K", 7.0, "AAA"),
        b.add("def1", "Alpha Defense", "DEF", 6.0, "AAA"),
        b.add("rb4", "Ryan Delta", "RB", 4.0, "DDD"),
        b.add("wr4", "Wes Delta", "WR", 3.5, "DDD"),
        b.add("rb5", "Ryan Echo", "RB", 12.0, "EEE"),
    ]
    my_starters = ["qb1", "rb1", "rb2", "wr1", "wr2", "te1", "te2", "k1", "def1"]

    # --- three opponents ---------------------------------------------
    opp_rosters = []
    layouts = [
        ("qb", "QB", [17.0, 10.0]),
        ("rb", "RB", [15.5, 12.5, 8.0]),
        ("wr", "WR", [14.5, 12.0, 7.5]),
        ("te", "TE", [9.5, 5.0]),
        ("k", "K", [6.5]),
        ("def", "DEF", [5.5]),
    ]
    # Team 2 is deliberately TE-rich and RB-poor so that a mutually
    # beneficial trade with roster 1 exists in the fixtures.
    point_overrides = {"t2_te1": 10.2, "t2_te2": 12.0, "t2_wr3": 12.4, "t2_rb2": 8.0}
    for team_index in range(2, 5):
        players = []
        starters_by_pos = {}
        for prefix, position, values in layouts:
            for slot_index, value in enumerate(values):
                pid = "t%d_%s%d" % (team_index, prefix, slot_index + 1)
                name = "Team%d %s%d" % (team_index, position, slot_index + 1)
                points = point_overrides.get(pid, round(value + team_index * 0.25, 2))
                b.add(pid, name, position, points, TEAMS[team_index])
                players.append(pid)
                starters_by_pos.setdefault(position, []).append(pid)
        starters = [
            starters_by_pos["QB"][0],
            starters_by_pos["RB"][0],
            starters_by_pos["RB"][1],
            starters_by_pos["WR"][0],
            starters_by_pos["WR"][1],
            starters_by_pos["TE"][0],
            starters_by_pos["RB"][2],
            starters_by_pos["K"][0],
            starters_by_pos["DEF"][0],
        ]
        opp_rosters.append((team_index, players, starters))

    # --- free agents ---------------------------------------------------
    b.add("fa_wr1", "Free Wide One", "WR", 16.5, "EEE", depth_chart_order=1)
    b.add("fa_wr2", "Free Wide Two", "WR", 10.0, "FFF", depth_chart_order=2)
    b.add("fa_rb1", "Free Run One", "RB", 12.0, "EEE", depth_chart_order=1)
    b.add("fa_rb2", "Free Run Two", "RB", 5.0, "FFF", depth_chart_order=3)
    b.add("fa_qb1", "Free Quarter One", "QB", 16.0, "GGG", depth_chart_order=1)
    b.add("fa_te1", "Free Tight One", "TE", 9.0, "GGG", depth_chart_order=1)
    b.add("fa_k1", "Free Kick One", "K", 8.5, "HHH", depth_chart_order=1)
    b.add("fa_def1", "Hotel Defense", "DEF", 7.5, "HHH", depth_chart_order=1)
    b.add("fa_out1", "Free Hurt One", "WR", 15.0, "EEE", injury_status="Out")
    b.add("fa_inactive1", "Free Retired One", "RB", 14.0, "FFF", status="Inactive", active=False)
    b.add("fa_quest1", "Free Doubt One", "WR", 11.0, "GGG", injury_status="Questionable")

    rosters = [
        {
            "roster_id": 1,
            "owner_id": "u1",
            "league_id": "100000000000000001",
            "players": my_players,
            "starters": my_starters,
            "reserve": None,
            "taxi": None,
            "settings": {"wins": 3, "losses": 1, "waiver_budget_used": 20, "waiver_position": 4},
        }
    ]
    for team_index, players, starters in opp_rosters:
        rosters.append(
            {
                "roster_id": team_index,
                "owner_id": "u%d" % team_index,
                "league_id": "100000000000000001",
                "players": players,
                "starters": starters,
                "reserve": None,
                "taxi": None,
                "settings": {
                    "wins": 2,
                    "losses": 2,
                    "waiver_budget_used": 10,
                    "waiver_position": team_index,
                },
            }
        )

    users = [
        {
            "user_id": "u1",
            "display_name": "TestManager",
            "metadata": {"team_name": "Test Titans"},
        }
    ]
    for team_index in range(2, 5):
        users.append(
            {
                "user_id": "u%d" % team_index,
                "display_name": "manager%d" % team_index,
                "metadata": {"team_name": "Team %d" % team_index},
            }
        )

    matchups = [
        {"roster_id": 1, "matchup_id": 1, "points": 0, "starters": my_starters, "players": my_players},
        {
            "roster_id": 2,
            "matchup_id": 1,
            "points": 0,
            "starters": rosters[1]["starters"],
            "players": rosters[1]["players"],
        },
        {
            "roster_id": 3,
            "matchup_id": 2,
            "points": 0,
            "starters": rosters[2]["starters"],
            "players": rosters[2]["players"],
        },
        {
            "roster_id": 4,
            "matchup_id": 2,
            "points": 0,
            "starters": rosters[3]["starters"],
            "players": rosters[3]["players"],
        },
    ]

    league = {
        "league_id": "100000000000000001",
        "name": "Test League",
        "season": "2025",
        "season_type": "regular",
        "total_rosters": 4,
        "status": "in_season",
        "roster_positions": [
            "QB", "RB", "RB", "WR", "WR", "TE", "FLEX", "K", "DEF",
            "BN", "BN", "BN", "BN", "BN",
        ],
        "scoring_settings": dict(PPR_SCORING),
        "settings": {"waiver_type": 2, "waiver_budget": 100, "num_teams": 4, "playoff_week_start": 15},
    }

    return {
        "state": {"season": "2025", "week": 5, "season_type": "regular", "display_week": 5},
        "league": league,
        "rosters": rosters,
        "users": users,
        "matchups": matchups,
        "user": {"user_id": "u1", "username": "testmanager", "display_name": "TestManager"},
        "players": b.players,
        "projections": b.projections,
        "trending_add": [
            {"player_id": "fa_wr1", "count": 4200},
            {"player_id": "fa_rb1", "count": 2100},
            {"player_id": "fa_te1", "count": 300},
        ],
        "transactions": [
            {"transaction_id": "tx1", "type": "waiver", "status": "complete", "roster_ids": [2]}
        ],
        "schedule": schedule_for({}),
    }


def schedule_for(status_by_week_team: dict) -> list:
    """Weeks 5 and 6, four games each; every game pre_game unless overridden
    as {(week, team): status}."""
    games = []
    for week in (5, 6):
        for i in range(0, len(TEAMS), 2):
            home, away = TEAMS[i], TEAMS[i + 1]
            status = status_by_week_team.get((week, home)) or status_by_week_team.get((week, away)) or "pre_game"
            games.append(
                {
                    "week": week,
                    "game_id": "g%d_%s" % (week, home),
                    "date": "2025-10-0%d" % (week - 3),
                    "home": home,
                    "away": away,
                    "status": status,
                }
            )
    return games


FUTURE_WEEKS = (6, 7, 8)


def with_future(data: dict, overrides: dict | None = None, weeks=FUTURE_WEEKS) -> dict:
    """Add projections_w6..w8 (copies of week 5 unless already present).
    `overrides` maps week -> {player_id: points or None (no projection)}."""
    overrides = overrides or {}
    base = data.get("projections")
    if not isinstance(base, list):
        return data
    for week in weeks:
        key = "projections_w%d" % week
        if key in data:
            continue
        records = []
        for record in base:
            if not isinstance(record, dict) or "player_id" not in record:
                continue
            record = copy.deepcopy(record)
            record["week"] = week
            records.append(record)
        for pid, points in (overrides.get(week) or {}).items():
            records = [r for r in records if r["player_id"] != pid]
            if points is not None:
                position = data["players"][pid]["position"]
                stats = stat_line(position, points)
                stats["pts_ppr"] = points
                records.append({"player_id": pid, "week": week, "season": "2025",
                                "season_type": "regular", "company": "synthetic", "stats": stats})
        data[key] = records
    return data


HISTORY_WEEKS = (1, 2, 3, 4)
HISTORY_SPREAD = {"QB": 6.0, "RB": 7.0, "WR": 7.0, "TE": 5.0, "K": 4.0, "DEF": 5.0}


def unit(seed: str) -> float:
    """Deterministic value in [-1, 1) from a string."""
    h = 2166136261
    for ch in seed:
        h = ((h ^ ord(ch)) * 16777619) & 0xFFFFFFFF
    return (h % 20000) / 10000.0 - 1.0


def with_history(data: dict, overrides: dict | None = None) -> dict:
    """Add weeks 1-4: projections_wN, stats_wN (actual stat lines with usage)
    and matchups_wN (league points per rostered player).
    `overrides` maps player_id -> {week: (projection, actual, snap_share)}."""
    overrides = overrides or {}
    rostered = {}
    for roster in data["rosters"]:
        for pid in roster.get("players") or []:
            rostered[pid] = roster["roster_id"]
    base = {r["player_id"]: r["stats"]["pts_ppr"] for r in data["projections"]}
    for week in HISTORY_WEEKS:
        proj_records, stat_records = [], []
        points_by_roster: dict = {}
        for pid, points in sorted(base.items()):
            player = data["players"].get(pid)
            if player is None:
                continue
            position = player["position"]
            proj = round(points * (1 + 0.04 * unit("p%s%d" % (pid, week))), 2)
            actual = round(max(0.0, proj + HISTORY_SPREAD.get(position, 5.0) * unit("a%s%d" % (pid, week))), 2)
            share = 0.85 if (player.get("depth_chart_order") or 1) == 1 else 0.45
            if pid in overrides and week in overrides[pid]:
                proj, actual, share = overrides[pid][week]
            stats = stat_line(position, proj)
            stats["pts_ppr"] = proj
            proj_records.append({"player_id": pid, "week": week, "season": "2025", "season_type": "regular",
                                 "company": "synthetic", "stats": stats})
            line = stat_line(position, actual)
            line["pts_ppr"] = actual
            if position not in ("K", "DEF"):
                line["off_snp"] = round(65 * share)
                line["tm_off_snp"] = 65
            if position in ("WR", "TE", "RB"):
                line["rec_tgt"] = round(share * (9 if position == "WR" else 6 if position == "TE" else 4))
            if position in ("RB", "QB"):
                line["rush_att"] = round(share * (18 if position == "RB" else 4))
            stat_records.append({"player_id": pid, "week": week, "season": "2025", "season_type": "regular",
                                 "stats": line})
            if pid in rostered:
                points_by_roster.setdefault(rostered[pid], {})[pid] = actual
        data["projections_w%d" % week] = proj_records
        data["stats_w%d" % week] = stat_records
        data["matchups_w%d" % week] = [
            {"roster_id": rid, "matchup_id": (rid + 1) // 2, "points": round(sum(pp.values()), 2),
             "players_points": pp} for rid, pp in sorted(points_by_roster.items())
        ]
    return data


def nflverse_csvs(data: dict, team_codes: dict | None = None) -> dict:
    """nflverse-style weekly player stats and snap counts built from the
    stats_wN fixtures (GSIS ids where players have one, names otherwise)."""
    team_codes = team_codes or {}
    stats_out, snaps_out = io.StringIO(), io.StringIO()
    sw = csv.writer(stats_out, lineterminator="\n")
    sw.writerow(["player_id", "player_name", "player_display_name", "position", "season", "week", "season_type",
                 "team", "carries", "targets", "target_share"])
    nw = csv.writer(snaps_out, lineterminator="\n")
    nw.writerow(["game_id", "season", "game_type", "week", "player", "pfr_player_id", "position", "team",
                 "offense_snaps", "offense_pct"])
    for week in HISTORY_WEEKS:
        for record in data.get("stats_w%d" % week) or []:
            player = data["players"].get(record["player_id"])
            if player is None or player["position"] in ("K", "DEF"):
                continue
            stats = record["stats"]
            team = team_codes.get(player["team"], player["team"])
            sw.writerow([player.get("gsis_id") or "", player["full_name"], player["full_name"], player["position"],
                         2025, week, "REG", team, stats.get("rush_att", 0), stats.get("rec_tgt", 0),
                         round(stats.get("rec_tgt", 0) / 35.0, 4)])
            if stats.get("tm_off_snp"):
                nw.writerow(["2025_%02d" % week, 2025, "REG", week, player["full_name"], "pfr" + record["player_id"],
                             player["position"], team, stats["off_snp"], round(stats["off_snp"] / stats["tm_off_snp"], 2)])
    return {"nflverse_stats.csv": stats_out.getvalue(), "nflverse_snaps.csv": snaps_out.getvalue()}


ESPN_POS = {"QB": 1, "RB": 2, "WR": 3, "TE": 4, "K": 5, "DEF": 16}
ESPN_TEAM_IDS = {"BUF": 2, "MIA": 15}


def espn_payload(data: dict, week: int, points: dict) -> dict:
    """ESPN kona_player_info-style response: {"players": [{"player": ...}]}.
    `points` maps Sleeper player id -> ESPN PPR projection."""
    entries = []
    for pid, value in sorted(points.items()):
        info = data["players"][pid]
        espn_id = info.get("espn_id")
        entries.append({"id": espn_id or 900000 + len(entries), "player": {
            "id": espn_id or 900000 + len(entries), "fullName": info["full_name"],
            "defaultPositionId": ESPN_POS[info["position"]],
            "proTeamId": ESPN_TEAM_IDS.get(info["team"], 99),
            "stats": [
                {"seasonId": 2025, "scoringPeriodId": week, "statSourceId": 1, "statSplitTypeId": 1,
                 "externalId": "2025%d" % week, "appliedTotal": value, "stats": {"53": 4.0}},
                # last season's projection for the same week: must be ignored
                {"seasonId": 2024, "scoringPeriodId": week, "statSourceId": 1, "statSplitTypeId": 1,
                 "externalId": "2024%d" % week, "appliedTotal": 77.0, "stats": {}},
                {"seasonId": 2025, "scoringPeriodId": week - 1, "statSourceId": 0, "statSplitTypeId": 1,
                 "appliedTotal": 99.0, "stats": {}},
            ]}})
    return {"players": entries}


def espn_files(data: dict, weeks, overrides: dict) -> dict:
    """espn.json / espn_wN.json: ESPN within 5% of Sleeper, except `overrides`
    ({player_id: ESPN points}, every week). Players need espn_id set."""
    data = with_future(data)
    files = {}
    for week in weeks:
        key = "projections" if week == 5 else "projections_w%d" % week
        values = {}
        for record in data[key]:
            pid = record["player_id"]
            if data["players"].get(pid, {}).get("position") not in ESPN_POS:
                continue
            ppr = record["stats"]["pts_ppr"]
            values[pid] = round(ppr * (1.05 if unit("e%s%d" % (pid, week)) > 0 else 0.95), 2)
        values.update(overrides)
        files[("espn" if week == 5 else "espn_w%d" % week) + ".json"] = json.dumps(
            espn_payload(data, week, values), indent=1, sort_keys=True) + "\n"
    return files


ESPN_SLOT_IDS = {"QB": 0, "RB": 2, "WR": 4, "TE": 6, "FLEX": 23, "K": 17, "DEF": 16}
ESPN_LEAGUE_ID = 555001
# PPR in ESPN's scoring items, plus a bonus with no projected stat (37) and
# defense items that only apply to the D/ST slot.
ESPN_SCORING_ITEMS = [
    {"statId": 3, "points": 0.04, "pointsOverrides": {}}, {"statId": 4, "points": 4.0, "pointsOverrides": {}},
    {"statId": 20, "points": -2.0, "pointsOverrides": {}}, {"statId": 24, "points": 0.1, "pointsOverrides": {}},
    {"statId": 25, "points": 6.0, "pointsOverrides": {}}, {"statId": 42, "points": 0.1, "pointsOverrides": {}},
    {"statId": 43, "points": 6.0, "pointsOverrides": {}}, {"statId": 53, "points": 1.0, "pointsOverrides": {}},
    {"statId": 72, "points": -2.0, "pointsOverrides": {}}, {"statId": 37, "points": 3.0, "pointsOverrides": {}},
    {"statId": 86, "points": 1.0, "pointsOverrides": {}}, {"statId": 80, "points": 3.0, "pointsOverrides": {}},
    {"statId": 89, "points": 0.0, "pointsOverrides": {"16": 5.0}},
    {"statId": 92, "points": 0.0, "pointsOverrides": {"16": 1.0}},
    {"statId": 99, "points": 0.0, "pointsOverrides": {"16": 1.0}},
]


def espn_league_files(data: dict, weeks, host_bonus: float = 2.5) -> dict:
    """The league as ESPN serves it: espn_league.json (settings, teams and
    rosters), espn_matchups.json (the week's box scores) and espn_host*.json
    (league-scored kicker / defense projections, `host_bonus` above the
    PPR ones). Players need espn_id set; one is left to match by name, and
    one bench player exists only on ESPN."""
    data = with_future(data)
    players = data["players"]
    slots = [p for p in data["league"]["roster_positions"] if p != "BN"]
    team_names = {u["user_id"]: u["metadata"]["team_name"] for u in data["users"]}

    def entry(pid: str, slot_id: int) -> dict:
        info = players[pid]
        espn_id = info.get("espn_id") or 770000 + sorted(players).index(pid)
        return {"lineupSlotId": slot_id, "playerId": espn_id, "playerPoolEntry": {
            "appliedStatTotal": 0.0,
            "player": {"id": espn_id, "fullName": info["full_name"], "defaultPositionId": ESPN_POS[info["position"]],
                       "proTeamId": ESPN_TEAM_IDS.get(info["team"], 99),
                       "injuryStatus": (info.get("injury_status") or "ACTIVE").upper()}}}

    def entries(roster: dict) -> list:
        starters = [pid for pid in roster["starters"] if pid in players]
        out = [entry(pid, ESPN_SLOT_IDS[slots[i]]) for i, pid in enumerate(roster["starters"]) if pid in players]
        out += [entry(pid, 20) for pid in roster["players"] if pid in players and pid not in starters]
        return out

    counts = {str(i): 0 for i in range(25)}
    for slot in slots:
        counts[str(ESPN_SLOT_IDS[slot])] += 1
    counts["20"], counts["21"] = 6, 1
    teams, games = [], {}
    for roster in data["rosters"]:
        rid = roster["roster_id"]
        name = team_names[roster["owner_id"]]
        rows = entries(roster)
        if rid == 2:
            rows.append({"lineupSlotId": 20, "playerId": 999001, "playerPoolEntry": {"appliedStatTotal": 0.0, "player": {
                "id": 999001, "fullName": "Espn Only", "defaultPositionId": 3, "proTeamId": 2,
                "injuryStatus": "QUESTIONABLE"}}})
        teams.append({"id": rid, "name": name, "abbrev": "".join(w[0] for w in name.split()).upper(),
                      "waiverRank": rid, "transactionCounter": {"acquisitionBudgetSpent": 0},
                      "roster": {"entries": rows}})
        matchup = next(m for m in data["matchups"] if m["roster_id"] == rid)
        side = {"teamId": rid, "totalPoints": 0.0, "pointsByScoringPeriod": {"5": 0.0},
                "rosterForCurrentScoringPeriod": {"entries": rows}}
        games.setdefault(matchup["matchup_id"], []).append(side)
    league = {
        "id": ESPN_LEAGUE_ID, "seasonId": 2025, "scoringPeriodId": 5,
        "status": {"currentMatchupPeriod": 5, "finalScoringPeriod": 16, "isActive": True},
        "settings": {
            "name": "ESPN Test League", "size": len(teams), "isPublic": True,
            "acquisitionSettings": {"acquisitionBudget": 100, "isUsingAcquisitionBudget": False},
            "rosterSettings": {"lineupSlotCounts": counts},
            "scheduleSettings": {"playoffTeamCount": 4, "matchupPeriods": {str(w): [w] for w in range(1, 17)}},
            "scoringSettings": {"scoringItems": ESPN_SCORING_ITEMS},
            "tradeSettings": {"deadlineDate": 1700000000000},
        },
        "teams": teams,
    }
    schedule = [{"id": mid, "matchupPeriodId": 5, "home": sides[0], "away": sides[1]}
                for mid, sides in sorted(games.items())]
    files = {"espn_league.json": league, "espn_matchups.json": {"id": ESPN_LEAGUE_ID, "schedule": schedule}}
    for week in weeks:
        key = "projections" if week == 5 else "projections_w%d" % week
        values = {r["player_id"]: round(r["stats"]["pts_ppr"] + host_bonus, 2) for r in data[key]
                  if players.get(r["player_id"], {}).get("position") in ("K", "DEF")}
        files[("espn_host" if week == 5 else "espn_host_w%d" % week) + ".json"] = espn_payload(data, week, values)
    return {name: json.dumps(value, indent=1, sort_keys=True) + "\n" for name, value in files.items()}


def write_case(out_dir: str, name: str, data: dict, raw: dict | None = None) -> None:
    case_dir = os.path.join(out_dir, name)
    os.makedirs(case_dir, exist_ok=True)
    data = with_future(dict(data))  # shallow copy: never mutate the caller's data
    for key, value in data.items():
        with open(os.path.join(case_dir, "%s.json" % key), "w", encoding="utf-8", newline="\n") as fh:
            json.dump(value, fh, indent=1, sort_keys=True)
            fh.write("\n")
    for key, value in (raw or {}).items():
        path = os.path.join(case_dir, key)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(value)


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT
    os.makedirs(out_dir, exist_ok=True)

    base = build_base()
    write_case(out_dir, "ppr_basic", base)

    # 1. custom scoring: TE premium, negative bonus and an unsupported category
    custom = copy.deepcopy(base)
    custom["league"]["scoring_settings"].update(
        {"rec_te": 1.5, "bonus_rec_yd_100": 3, "idp_tkl_solo": 1.0}
    )
    custom["league"]["name"] = "Custom Scoring League"
    write_case(out_dir, "custom_scoring", custom)

    # 2. superflex
    superflex = copy.deepcopy(base)
    superflex["league"]["roster_positions"] = [
        "QB", "RB", "RB", "WR", "WR", "TE", "SUPER_FLEX", "K", "DEF",
        "BN", "BN", "BN", "BN", "BN",
    ]
    write_case(out_dir, "superflex", superflex)

    # 3. multiple overlapping flex slots
    overlap = copy.deepcopy(base)
    overlap["league"]["roster_positions"] = [
        "QB", "RB", "WR", "TE", "FLEX", "WRRB_FLEX", "REC_FLEX", "SUPER_FLEX",
        "BN", "BN", "BN", "BN", "BN", "BN",
    ]
    overlap["rosters"][0]["starters"] = [
        "qb1", "rb1", "wr1", "te1", "rb2", "wr2", "te2", "qb2",
    ]
    for entry in overlap["matchups"]:
        if entry["roster_id"] == 1:
            entry["starters"] = overlap["rosters"][0]["starters"]
    write_case(out_dir, "overlapping_flex", overlap)

    # 4. empty starter placeholders and a short starters array
    empty = copy.deepcopy(base)
    empty["rosters"][0]["starters"] = ["qb1", "0", "rb2", None, "wr2", "te1"]
    write_case(out_dir, "empty_starters", empty)

    # 5. null players/starters/owner/team name on other rosters
    nulls = copy.deepcopy(base)
    nulls["rosters"][2]["players"] = None
    nulls["rosters"][2]["starters"] = None
    nulls["rosters"][3]["owner_id"] = None
    nulls["users"][3]["metadata"] = {}
    write_case(out_dir, "null_fields", nulls)

    # 6. starter missing from the player database
    missing = copy.deepcopy(base)
    missing["players"].pop("wr2", None)
    write_case(out_dir, "missing_player", missing)

    # 7. projection feed returns HTML
    html = copy.deepcopy(base)
    del html["projections"]
    write_case(
        out_dir,
        "projections_html",
        html,
        raw={"projections.json": "<html><body>502 Bad Gateway</body></html>\n"},
    )

    # 8. projection feed returns malformed JSON
    malformed = copy.deepcopy(base)
    del malformed["projections"]
    write_case(out_dir, "projections_malformed", malformed, raw={"projections.json": '[{"player_id": \n'})

    # 9. projection feed returns an empty array
    empty_proj = copy.deepcopy(base)
    empty_proj["projections"] = []
    write_case(out_dir, "projections_empty", empty_proj)

    # 10. projection feed schema change (no player_id / stats)
    schema = copy.deepcopy(base)
    schema["projections"] = [{"id": "x1", "points": 12.3}, {"id": "x2", "points": 8.1}]
    write_case(out_dir, "projections_schema_change", schema)

    # 11. HTTP 429 on projections, no cache available
    http429 = copy.deepcopy(base)
    del http429["projections"]
    write_case(out_dir, "http_429", http429, raw={"projections.status": "429\n"})

    # 12. HTTP 500 on the league endpoint
    http500 = copy.deepcopy(base)
    del http500["league"]
    write_case(out_dir, "http_500", http500, raw={"league.status": "500\n"})

    # 13. stale cache fallback: projections unavailable, cache seeded by run.sh
    stale = copy.deepcopy(base)
    stale_projections = stale.pop("projections")
    write_case(out_dir, "stale_cache", stale, raw={"projections.status": "503\n"})
    with open(
        os.path.join(out_dir, "stale_cache", "projections_cache_seed.json"),
        "w",
        encoding="utf-8",
        newline="\n",
    ) as fh:
        json.dump(stale_projections, fh, indent=1, sort_keys=True)
        fh.write("\n")

    # 14. no eligible player for a required slot (roster has no kicker)
    no_k = copy.deepcopy(base)
    no_k["rosters"][0]["players"] = [p for p in no_k["rosters"][0]["players"] if p != "k1"]
    no_k["rosters"][0]["starters"] = [
        p if p != "k1" else "0" for p in no_k["rosters"][0]["starters"]
    ]
    for pid in list(no_k["players"]):
        if no_k["players"][pid]["position"] == "K":
            no_k["players"].pop(pid)
    no_k["projections"] = [
        p for p in no_k["projections"] if p["player_id"] not in ("k1", "fa_k1")
        and not p["player_id"].endswith("_k1")
    ]
    write_case(out_dir, "no_eligible_slot", no_k)

    # 15. one rostered starter has no projection at all
    no_proj = copy.deepcopy(base)
    no_proj["projections"] = [p for p in no_proj["projections"] if p["player_id"] != "wr1"]
    write_case(out_dir, "missing_projection", no_proj)

    # 16. current lineup already optimal
    optimal = copy.deepcopy(base)
    optimal["rosters"][0]["starters"] = [
        "qb1", "rb1", "rb3", "wr1", "wr3", "te1", "rb5", "k1", "def1",
    ]
    for entry in optimal["matchups"]:
        if entry["roster_id"] == 1:
            entry["starters"] = optimal["rosters"][0]["starters"]
    write_case(out_dir, "already_optimal", optimal)

    # 17. unequal start/bench counts (two empty slots, one benching)
    unequal = copy.deepcopy(base)
    unequal["rosters"][0]["starters"] = ["qb1", "0", "0", "wr1", "wr2", "te1", "te2", "k1", "def1"]
    write_case(out_dir, "unequal_changes", unequal)

    # 18. dynasty league with taxi and reserve players
    dynasty = copy.deepcopy(base)
    dynasty["league"]["settings"]["taxi_slots"] = 2
    dynasty["league"]["settings"]["reserve_slots"] = 2
    dynasty["rosters"][0]["taxi"] = ["wr3"]
    dynasty["rosters"][0]["reserve"] = ["rb3"]
    write_case(out_dir, "dynasty_taxi", dynasty)

    # 19. strong bench player on bye (no projection this week): must not be
    #     suggested as a waiver drop
    bye = copy.deepcopy(base)
    bye["projections"] = [p for p in bye["projections"] if p["player_id"] != "rb2"]
    # ...but he is back after the bye (week 6 onwards)
    with_future(bye, {week: {"rb2": 11.0} for week in FUTURE_WEEKS})
    write_case(out_dir, "bye_week_bench", bye)

    # 20. rolling waivers: Sleeper still fills in waiver_budget
    rolling = copy.deepcopy(base)
    rolling["league"]["settings"]["waiver_type"] = 0
    rolling["league"]["settings"]["waiver_budget"] = 100
    write_case(out_dir, "rolling_waivers", rolling)

    # 21. suspended player, reported by Sleeper as injury_status "Sus"
    suspended = copy.deepcopy(base)
    suspended["players"]["rb3"]["injury_status"] = "Sus"
    write_case(out_dir, "suspended_player", suspended)

    # 22. mixed locks: the CCC-DDD game is final (my bench rb3/wr3/rb4/wr4
    #     cannot be moved in) and live points lock my starting QB; everything
    #     else is still open.
    locked = copy.deepcopy(base)
    locked["schedule"] = schedule_for({(5, "CCC"): "complete"})
    for entry in locked["matchups"]:
        if entry["roster_id"] == 1:
            entry["players_points"] = {"qb1": 21.4, "rb3": 19.0, "wr3": 2.0}
            entry["points"] = 21.4
    # the best free agent's game is also final, and a locked bench player
    # carries a (now moot) Questionable tag
    locked["players"]["fa_wr1"]["team"] = "CCC"
    locked["players"]["rb3"]["injury_status"] = "Questionable"
    write_case(out_dir, "locked_players", locked)

    # 23. every week 5 game is final: the week rolls over to 6
    final = copy.deepcopy(base)
    final["schedule"] = schedule_for({(5, team): "complete" for team in TEAMS})
    write_case(out_dir, "week_complete", final)

    # 24. no schedule: locks come from live points only
    no_sched = copy.deepcopy(base)
    del no_sched["schedule"]
    for entry in no_sched["matchups"]:
        if entry["roster_id"] == 1:
            entry["players_points"] = {"rb2": 5.0, "wr3": 4.0, "qb1": 0}
    write_case(out_dir, "no_schedule", no_sched)

    # 25. league scores DEF/K categories the projection feed lacks
    kdef = copy.deepcopy(base)
    kdef["league"]["scoring_settings"].update({"pts_allow_0": 10, "fgm_50_59": 5})
    write_case(out_dir, "kdef_fallback", kdef)

    # 26. two-way player (listed DB, also WR-eligible) starting for roster 3
    two_way = copy.deepcopy(base)
    two_way["players"]["t3_two"] = dict(two_way["players"]["t3_wr1"])
    two_way["players"]["t3_two"].update(
        {"player_id": "t3_two", "full_name": "Team3 TwoWay", "first_name": "Team3",
         "last_name": "TwoWay", "position": "DB", "fantasy_positions": ["WR", "DB"]}
    )
    two_way["projections"].append(
        {"player_id": "t3_two", "week": 5, "season": "2025", "season_type": "regular",
         "company": "synthetic", "stats": {"rec": 6, "rec_yd": 90, "pts_ppr": 15.0}}
    )
    two_way["rosters"][2]["players"].append("t3_two")
    write_case(out_dir, "two_way_player", two_way)

    # 27. free agent on bye this week who projects well afterwards: a stash
    stash = copy.deepcopy(base)
    stash["players"]["fa_stash"] = dict(stash["players"]["fa_wr2"])
    stash["players"]["fa_stash"].update(
        {"player_id": "fa_stash", "full_name": "Free Stash One", "first_name": "Free",
         "last_name": "Stash", "team": "III", "depth_chart_order": 1}
    )
    with_future(stash, {week: {"fa_stash": 17.0} for week in FUTURE_WEEKS})
    write_case(out_dir, "stash_candidate", stash)

    # 28. a partner's quarterbacks are on bye this week only. Judged on this
    #     week alone, trading my QB1 to them looks good for both sides; over
    #     the window it is a bad deal for them, so it must not be proposed.
    bye_qb = copy.deepcopy(base)
    for pid in ("t3_qb1", "t3_qb2"):
        bye_qb["players"][pid]["team"] = "III"
    bye_qb["projections"] = [p for p in bye_qb["projections"] if p["player_id"] not in ("t3_qb1", "t3_qb2")]
    with_future(bye_qb, {week: {"t3_qb1": 17.75, "t3_qb2": 10.75} for week in FUTURE_WEEKS})
    write_case(out_dir, "bye_qb_partner", bye_qb)

    # 29. four past weeks of projections and results: projection accuracy,
    #     recent form; the stats feed failed for week 2 (league points only).
    #     A free agent's role grows every week, one of my starters fades.
    history = with_history(copy.deepcopy(base), {
        "fa_rb2": {1: (4.0, 3.0, 0.25), 2: (4.5, 6.5, 0.35), 3: (5.0, 11.0, 0.5), 4: (6.0, 15.5, 0.65)},
        "wr2": {1: (12.0, 14.0, 0.9), 2: (11.0, 9.0, 0.75), 3: (10.0, 5.0, 0.6), 4: (9.5, 3.0, 0.45)},
    })
    del history["stats_w2"]
    for i, pid in enumerate(sorted(history["players"])):
        history["players"][pid]["espn_id"] = 4000 + i
    history_raw = {"stats_w2.status": "404\n"}
    history_raw.update(espn_files(copy.deepcopy(history), (5,), {"wr1": 8.0, "fa_rb1": 18.0}))
    write_case(out_dir, "season_history", history, raw=history_raw)

    # 30. heavy underdog with a boom-or-bust bench back: the steady FLEX
    #     projects a little higher, but the volatile one gives a better
    #     chance to win.
    underdog = copy.deepcopy(base)
    for record in underdog["projections"]:
        if record["player_id"].startswith("t2_"):
            record["stats"] = {k: round(v * 1.35, 2) for k, v in record["stats"].items()}
    underdog = with_history(underdog, {
        "rb2": {1: (11.0, 0.0, 0.6), 2: (11.0, 30.0, 0.6), 3: (11.0, 0.0, 0.6), 4: (11.0, 30.0, 0.6)},
        "rb5": {1: (12.0, 12.5, 0.8), 2: (12.0, 11.0, 0.8), 3: (12.0, 12.0, 0.8), 4: (12.0, 13.0, 0.8)},
        # the best free agent's role has just grown (waiver row gets a note)
        "fa_wr1": {1: (12.0, 10.0, 0.4), 2: (13.0, 12.0, 0.5), 3: (15.0, 17.0, 0.8), 4: (16.0, 18.0, 0.9)},
    })
    write_case(out_dir, "underdog_volatile", underdog)

    # 31. the stats feed is down for every past week: usage comes from
    #     nflverse (GSIS ids for most players; the breakout back has none and
    #     plays for the Rams, "LA" in nflverse and "LAR" in Sleeper).
    nflv = copy.deepcopy(history)
    for i, pid in enumerate(sorted(nflv["players"])):
        nflv["players"][pid]["gsis_id"] = "00-00%05d" % i
    nflv["players"]["fa_rb2"]["gsis_id"] = None
    nflv["players"]["fa_rb2"]["team"] = "LAR"
    nflv["stats_w2"] = history_stats_w2 = with_history(copy.deepcopy(base), {
        "fa_rb2": {2: (4.5, 6.5, 0.35)}, "wr2": {2: (11.0, 9.0, 0.75)}})["stats_w2"]
    files = nflverse_csvs(nflv, {"LAR": "LA"})
    raw_status = {}
    for week in HISTORY_WEEKS:
        nflv.pop("stats_w%d" % week, None)
        raw_status["stats_w%d.status" % week] = "404\n"
    raw_status.update(files)
    del history_stats_w2
    write_case(out_dir, "usage_nflverse", nflv, raw=raw_status)

    # 32. rest of season: projections through week 17 (the league's last
    #     playoff week), a partner back on bye this week only, and a trade
    #     deadline that has passed.
    ros = copy.deepcopy(base)
    ros["league"]["settings"].update({"playoff_teams": 4, "playoff_round_type": 1, "trade_deadline": 4})
    ros["projections"] = [p for p in ros["projections"] if p["player_id"] != "t2_rb1"]
    ros_weeks = tuple(range(6, 18))
    with_future(ros, {week: {"t2_rb1": 15.75} for week in ros_weeks}, weeks=ros_weeks)
    write_case(out_dir, "rest_of_season", ros)

    # 33. a second projection source (ESPN format). ESPN is much lower on my
    #     starting WR1 and higher on a free-agent back; one player has no
    #     ESPN id and is matched by name and team; the rest roughly agree.
    espn = copy.deepcopy(base)
    for i, pid in enumerate(sorted(espn["players"])):
        espn["players"][pid]["espn_id"] = 4000 + i
    espn["players"]["wr3"]["espn_id"] = None
    espn["players"]["wr3"]["team"] = "BUF"
    espn = with_future(espn)
    write_case(out_dir, "espn_compare", espn,
               raw=espn_files(espn, (5,) + FUTURE_WEEKS, {"wr1": 8.0, "fa_rb1": 18.0}))

    # 34. the same league hosted on ESPN: rosters, lineup slots, scoring and
    #     matchups in ESPN's format. Kickers and defenses use ESPN's
    #     league-scored projections (2.5 above the PPR ones); the trade
    #     deadline has passed; week 8 has no ESPN kicker/defense projections.
    espn_lg = copy.deepcopy(espn)
    espn_lg_raw = espn_files(espn_lg, (5,) + FUTURE_WEEKS, {})
    espn_lg_raw.update(espn_league_files(espn_lg, (5, 6, 7)))
    write_case(out_dir, "espn_league", espn_lg, raw=espn_lg_raw)

    print("fixtures written to %s" % out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
