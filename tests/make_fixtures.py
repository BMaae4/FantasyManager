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
    }


def write_case(out_dir: str, name: str, data: dict, raw: dict | None = None) -> None:
    case_dir = os.path.join(out_dir, name)
    os.makedirs(case_dir, exist_ok=True)
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

    print("fixtures written to %s" % out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
