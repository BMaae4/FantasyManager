#!/usr/bin/env python3
"""Generate the sanitized offline fixtures used by tests/run.sh.

Everything here is synthetic: fake player ids, fake names, fake teams and
deterministic projected stat lines.  No real Sleeper payloads are committed.

Usage: python3 tests/make_fixtures.py [output_dir]
"""

from __future__ import annotations

import copy
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
            "league_id": "1400680781302525952",
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
                "league_id": "1400680781302525952",
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
            "display_name": "MaTrasaMaae",
            "metadata": {"team_name": "Trasa Titans"},
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
        "league_id": "1400680781302525952",
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
        "user": {"user_id": "u1", "username": "matrasamaae", "display_name": "MaTrasaMaae"},
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


def with_future(data: dict, overrides: dict | None = None) -> dict:
    """Add projections_w6..w8 (copies of week 5 unless already present).
    `overrides` maps week -> {player_id: points or None (no projection)}."""
    overrides = overrides or {}
    base = data.get("projections")
    if not isinstance(base, list):
        return data
    for week in FUTURE_WEEKS:
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
    write_case(out_dir, "season_history", history, raw={"stats_w2.status": "404\n"})

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
    })
    write_case(out_dir, "underdog_volatile", underdog)

    print("fixtures written to %s" % out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
