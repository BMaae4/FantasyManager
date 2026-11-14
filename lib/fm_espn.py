"""ESPN leagues for fantasy_manager.

Reads a league from ESPN's fantasy API (unofficial) and converts it to the
league documents the analysis already understands: the league (slots,
scoring, waiver and playoff settings), rosters, team names and the week's
matchups, with every player mapped to the player database's ids.

Standard library only; the conversion is pure so it can be tested offline.
"""

from __future__ import annotations

import json
from typing import Any, Dict, List, Optional, Tuple

import fm_providers

# Lineup slot ids -> the slot names the lineup optimiser knows.
SLOTS = {
    0: "QB", 2: "RB", 3: "WRRB_FLEX", 4: "WR", 5: "REC_FLEX", 6: "TE", 7: "SUPER_FLEX",
    8: "DT", 9: "DE", 10: "LB", 11: "DL", 12: "CB", 13: "S", 14: "DB", 15: "IDP_FLEX",
    16: "DEF", 17: "K", 23: "FLEX",
}
SLOT_ORDER = [0, 2, 3, 4, 5, 6, 23, 7, 16, 17, 8, 9, 10, 11, 12, 13, 14, 15]
BENCH_SLOT, IR_SLOT = 20, 21
SLOT_LABELS = {1: "team QB", 18: "punter", 19: "head coach", 22: "unknown", 24: "unknown"}

# Scoring stat ids -> projected stat keys. One ESPN item can cover several
# keys (field goals under 40 yards are three distance buckets).
SCORING = {
    0: ("pass_att",), 1: ("pass_cmp",), 2: ("pass_inc",), 3: ("pass_yd",), 4: ("pass_td",),
    19: ("pass_2pt",), 20: ("pass_int",), 23: ("rush_att",), 24: ("rush_yd",), 25: ("rush_td",),
    26: ("rush_2pt",), 42: ("rec_yd",), 43: ("rec_td",), 44: ("rec_2pt",), 53: ("rec",),
    58: ("rec_tgt",), 64: ("pass_sack",), 68: ("fum",), 72: ("fum_lost",),
    # Kickers and team defenses: used for past weeks only. This week and the
    # window use ESPN's own league-scored projections (host points).
    74: ("fgm_50p",), 77: ("fgm_40_49",), 80: ("fgm_0_19", "fgm_20_29", "fgm_30_39"),
    85: ("fgmiss_0_19", "fgmiss_20_29", "fgmiss_30_39", "fgmiss_40_49", "fgmiss_50p"),
    86: ("xpm",), 88: ("xpmiss",),
    89: ("pts_allow_0",), 90: ("pts_allow_1_6",), 91: ("pts_allow_7_13",), 123: ("pts_allow_28_34",),
    95: ("int",), 96: ("fum_rec",), 97: ("blk_kick",), 98: ("safe",), 99: ("sack",), 106: ("ff",),
    101: ("def_kr_td",), 102: ("def_pr_td",),
}
# 50-59 yard field goals stand in for 50+ when the league has no 50+ item.
FG_50_59 = 198
# A reception bonus for one position (TE premium) is a slot override on receptions.
RECEPTION_BONUS = {"2": "bonus_rec_rb", "4": "bonus_rec_wr", "6": "bonus_rec_te"}
SCORING_NAMES = {
    15: "40+ yard TD pass", 16: "50+ yard TD pass", 17: "300-399 yard passing game", 18: "400+ yard passing game",
    35: "40+ yard TD run", 36: "50+ yard TD run", 37: "100-199 yard rushing game", 38: "200+ yard rushing game",
    45: "40+ yard TD catch", 46: "50+ yard TD catch", 56: "100-199 yard receiving game",
    57: "200+ yard receiving game", 63: "fumble recovered for a TD", 73: "turnover",
}
HOST_POSITIONS = ("K", "DEF")
HOST_SLOT_IDS = [17, 16]

INJURY = {"QUESTIONABLE": "Questionable", "DOUBTFUL": "Doubtful", "OUT": "Out",
          "INJURY_RESERVE": "IR", "SUSPENSION": "Sus"}


def is_kicking_or_defense(stat_id: int) -> bool:
    return 74 <= stat_id <= 136 or 198 <= stat_id <= 209


def league_url(base: str, season: str, league_id: str, views: List[str], week: Optional[int] = None) -> str:
    url = "%s/seasons/%s/segments/0/leagues/%s?%s" % (base, season, league_id, "&".join("view=" + v for v in views))
    return url + ("&scoringPeriodId=%d" % week if week is not None else "")


LEAGUE_VIEWS = ["mSettings", "mTeam", "mRoster", "mStatus"]
MATCHUP_VIEWS = ["mBoxscore", "mMatchupScore"]
HOST_VIEWS = ["kona_player_info"]


def host_filter(season: str, week: int) -> str:
    """X-Fantasy-Filter for the league-scored weekly projections of kickers
    and team defenses (the same period codes as fm_providers.espn_filter)."""
    return json.dumps({"players": {
        "filterSlotIds": {"value": HOST_SLOT_IDS},
        "filterStatsForTopScoringPeriodIds": {"value": 2, "additionalValue": [
            "00%s" % season, "10%s" % season, "11%s%d" % (season, week), "01%s%d" % (season, week)]},
        "limit": 200,
        "sortPercOwned": {"sortPriority": 1, "sortAsc": False},
    }}, separators=(",", ":"))


def looks_like_league(doc: Any) -> bool:
    return (isinstance(doc, dict) and isinstance(doc.get("settings"), dict)
            and isinstance(doc.get("teams"), list) and len(doc["teams"]) > 0)


# -- players ---------------------------------------------------------------
class PlayerIndex:
    """ESPN players -> player database ids: by ESPN id, by name + team +
    position, by name + position or name alone when that is unique, and by
    team for defenses. A rostered player with no match gets an entry of his own
    ("espn-<id>") so he still shows up, without a projection."""

    def __init__(self, players: Dict[str, dict]) -> None:
        self.players = players
        self.by_espn: Dict[str, str] = {}
        self.by_name: Dict[Tuple[str, str, str], Optional[str]] = {}
        self.by_name_pos: Dict[Tuple[str, str], Optional[str]] = {}
        self.by_name_only: Dict[str, Optional[str]] = {}
        self.added: List[str] = []
        for pid, v in players.items():
            if not isinstance(v, dict):
                continue
            if v.get("espn_id") not in (None, ""):
                self.by_espn.setdefault(str(v["espn_id"]), pid)
            name = fm_providers._norm(v.get("full_name") or "")
            position = str(v.get("position") or "").upper()
            if not name:
                continue
            key = (name, str(v.get("team") or "").upper(), position)
            self.by_name[key] = None if key in self.by_name else pid
            loose = (name, position)
            self.by_name_pos[loose] = None if loose in self.by_name_pos else pid
            if v.get("team") and v.get("active") is not False:
                self.by_name_only[name] = None if name in self.by_name_only else pid

    def resolve(self, player: dict, add: bool = True) -> Optional[str]:
        espn_id = player.get("id")
        position = fm_providers.ESPN_POSITIONS.get(player.get("defaultPositionId"))
        team = fm_providers.ESPN_TEAMS.get(player.get("proTeamId"))
        if position == "DEF" and team and team in self.players:
            return team
        if position or espn_id is not None:
            pid = self.by_espn.get(str(espn_id))
            if pid is None and position:
                name = fm_providers._norm(player.get("fullName") or "")
                # Name alone covers a player listed at another position (a two-way player).
                pid = (self.by_name.get((name, team or "", position)) or self.by_name_pos.get((name, position))
                       or self.by_name_only.get(name))
            if pid is not None:
                return pid
        if not add or espn_id is None:
            return None
        pid = "espn-%s" % espn_id
        if pid not in self.players:
            self.players[pid] = {
                "player_id": pid, "full_name": player.get("fullName") or pid, "position": position,
                "fantasy_positions": [position] if position else [], "team": team, "status": "Active",
                "injury_status": INJURY.get(str(player.get("injuryStatus") or "").upper()),
                "injury_notes": None, "practice_participation": None, "active": True, "years_exp": None,
                "depth_chart_position": None, "depth_chart_order": None, "news_updated": None,
                "gsis_id": None, "espn_id": espn_id,
            }
            self.added.append(str(player.get("fullName") or pid))
        return pid


def entry_player(entry: dict) -> dict:
    pool = entry.get("playerPoolEntry") if isinstance(entry.get("playerPoolEntry"), dict) else {}
    player = pool.get("player") if isinstance(pool.get("player"), dict) else {}
    if player.get("id") is None and entry.get("playerId") is not None:
        player = dict(player, id=entry["playerId"])
    return player


# -- league ----------------------------------------------------------------
def convert_scoring(items: List[dict]) -> Tuple[Dict[str, float], List[str]]:
    """ESPN scoringItems -> ({projected stat key: points}, offensive items
    that have no projected stat). Kicker and defense items without a stat
    are not reported: those positions use ESPN's league-scored projections."""
    scoring: Dict[str, float] = {}
    unmapped: List[str] = []
    seen = {i.get("statId") for i in items if isinstance(i, dict)}
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("statId"), int):
            continue
        stat_id = item["statId"]
        overrides = item.get("pointsOverrides") if isinstance(item.get("pointsOverrides"), dict) else {}
        points = item.get("points") if isinstance(item.get("points"), (int, float)) else 0.0
        if is_kicking_or_defense(stat_id):
            slot = "17" if stat_id < 89 or 198 <= stat_id <= 201 else "16"
            if isinstance(overrides.get(slot), (int, float)):
                points = overrides[slot]
        keys = SCORING.get(stat_id)
        if stat_id == FG_50_59 and 74 not in seen:
            keys = ("fgm_50p",)
        if stat_id == 53:
            for slot, bonus in RECEPTION_BONUS.items():
                if isinstance(overrides.get(slot), (int, float)) and overrides[slot] != points:
                    scoring[bonus] = float(overrides[slot]) - float(points)
        if not points:
            continue
        if keys is None:
            if not is_kicking_or_defense(stat_id):
                unmapped.append("%s (%+g)" % (SCORING_NAMES.get(stat_id, "ESPN stat %d" % stat_id), points))
            continue
        for key in keys:
            scoring[key] = float(points)
    return scoring, sorted(unmapped)


def starting_slot_ids(doc: dict) -> List[int]:
    counts = ((doc.get("settings") or {}).get("rosterSettings") or {}).get("lineupSlotCounts") or {}
    out: List[int] = []
    for slot_id in SLOT_ORDER:
        n = counts.get(str(slot_id))
        out += [slot_id] * (n if isinstance(n, int) and n > 0 else 0)
    return out


def convert_league(doc: dict) -> Tuple[dict, List[str]]:
    """The league document (settings + status) -> (league, warnings)."""
    settings = doc.get("settings") or {}
    status = doc.get("status") or {}
    warnings: List[str] = []
    counts = (settings.get("rosterSettings") or {}).get("lineupSlotCounts") or {}
    roster_positions = [SLOTS[s] for s in starting_slot_ids(doc)]
    for key, n in sorted(counts.items(), key=lambda kv: int(kv[0]) if str(kv[0]).isdigit() else 0):
        slot_id = int(key) if str(key).isdigit() else -1
        if isinstance(n, int) and n > 0 and slot_id not in SLOTS and slot_id not in (BENCH_SLOT, IR_SLOT):
            warnings.append("ESPN lineup slot %d (%s) is not supported and is left out of the lineup."
                            % (slot_id, SLOT_LABELS.get(slot_id, "unknown")))
    bench = counts.get(str(BENCH_SLOT))
    roster_positions += ["BN"] * (bench if isinstance(bench, int) and bench > 0 else 0)
    reserve = counts.get(str(IR_SLOT))
    roster_positions += ["IR"] * (reserve if isinstance(reserve, int) and reserve > 0 else 0)

    scoring_items = (settings.get("scoringSettings") or {}).get("scoringItems") or []
    scoring, unmapped = convert_scoring(scoring_items)
    if unmapped:
        warnings.append("%d ESPN scoring item(s) have no projected stat and are left out: %s."
                        % (len(unmapped), ", ".join(unmapped[:15])))

    acquisition = settings.get("acquisitionSettings") or {}
    faab = bool(acquisition.get("isUsingAcquisitionBudget"))
    schedule = settings.get("scheduleSettings") or {}
    deadline = (settings.get("tradeSettings") or {}).get("deadlineDate")
    final = status.get("finalScoringPeriod")
    league = {
        "league_id": str(doc.get("id")), "platform": "espn", "name": settings.get("name"),
        "total_rosters": settings.get("size") or len(doc.get("teams") or []),
        "roster_positions": roster_positions,
        "scoring_settings": scoring,
        "settings": {
            "waiver_type": 2 if faab else 0,
            "waiver_budget": acquisition.get("acquisitionBudget") if faab else None,
            "playoff_teams": schedule.get("playoffTeamCount"),
            "last_scoring_week": final if isinstance(final, int) and 1 <= final <= 18 else None,
            "trade_deadline_at": int(deadline / 1000) if isinstance(deadline, (int, float)) and deadline > 0 else None,
        },
    }
    return league, warnings


def find_team(doc: dict, wanted: str) -> Tuple[Optional[dict], List[str]]:
    """The team named `wanted`: a team id, or a team name or abbreviation
    (exact, then a unique part of the name). Also returns every team name."""
    teams = [t for t in (doc.get("teams") or []) if isinstance(t, dict) and t.get("id") is not None]
    names = [str(t.get("name") or t.get("abbrev") or t["id"]).strip() for t in teams]
    text = (wanted or "").strip().lower()
    if not text:
        return None, names
    if text.isdigit():
        for team in teams:
            if str(team["id"]) == text:
                return team, names
    for field in ("name", "abbrev"):
        exact = [t for t in teams if str(t.get(field) or "").strip().lower() == text]
        if len(exact) == 1:
            return exact[0], names
    partial = [t for t in teams if text in str(t.get("name") or "").lower()]
    return (partial[0] if len(partial) == 1 else None), names


def owner_id(team_id: Any) -> str:
    return "espn-team-%s" % team_id


def convert_teams(doc: dict, index: PlayerIndex) -> Tuple[List[dict], List[dict]]:
    """Teams with rosters -> (rosters, users). `starters` lines up with the
    league's starting slots; an empty slot is "0"."""
    slot_ids = starting_slot_ids(doc)
    rosters: List[dict] = []
    users: List[dict] = []
    for team in doc.get("teams") or []:
        if not isinstance(team, dict) or team.get("id") is None:
            continue
        name = str(team.get("name") or team.get("abbrev") or "Team %s" % team["id"]).strip()
        users.append({"user_id": owner_id(team["id"]), "display_name": name, "metadata": {"team_name": name}})
        entries = ((team.get("roster") or {}).get("entries")) or []
        players, reserve, starters = split_entries(entries, slot_ids, index)[:3]
        counter = team.get("transactionCounter") or {}
        rosters.append({
            "roster_id": team["id"], "owner_id": owner_id(team["id"]),
            "players": players, "starters": starters, "reserve": reserve,
            "settings": {"waiver_budget_used": counter.get("acquisitionBudgetSpent"),
                         "waiver_position": team.get("waiverRank")},
        })
    return rosters, users


def split_entries(entries: List[dict], slot_ids: List[int],
                  index: PlayerIndex) -> Tuple[List[str], List[str], List[str], Dict[str, float]]:
    """Roster entries -> (all players, IR players, starters by slot, points)."""
    players: List[str] = []
    reserve: List[str] = []
    points: Dict[str, float] = {}
    by_slot: Dict[int, List[str]] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        pid = index.resolve(entry_player(entry))
        if pid is None:
            continue
        players.append(pid)
        slot = entry.get("lineupSlotId")
        if slot == IR_SLOT:
            reserve.append(pid)
        elif slot in SLOTS:
            by_slot.setdefault(slot, []).append(pid)
        total = (entry.get("playerPoolEntry") or {}).get("appliedStatTotal")
        if isinstance(total, (int, float)) and not isinstance(total, bool):
            points[pid] = round(float(total), 2)
    starters = [(by_slot.get(slot_id) or ["0"]).pop(0) if by_slot.get(slot_id) else "0" for slot_id in slot_ids]
    return players, reserve, starters, points


def matchup_period(doc: dict, week: int) -> int:
    periods = (((doc.get("settings") or {}).get("scheduleSettings") or {}).get("matchupPeriods")) or {}
    for key, weeks in periods.items():
        if isinstance(weeks, list) and week in weeks and str(key).isdigit():
            return int(key)
    return week


def convert_matchups(doc: dict, league_doc: dict, week: int, index: PlayerIndex) -> List[dict]:
    """The week's box scores -> one matchup entry per team, with each
    player's points so far."""
    slot_ids = starting_slot_ids(league_doc)
    period = matchup_period(league_doc, week)
    out: List[dict] = []
    for game in doc.get("schedule") or []:
        if not isinstance(game, dict) or game.get("matchupPeriodId") != period:
            continue
        for side in ("home", "away"):
            team = game.get(side)
            if not isinstance(team, dict) or team.get("teamId") is None:
                continue
            roster = team.get("rosterForCurrentScoringPeriod")
            if not isinstance(roster, dict):
                continue
            _, _, starters, points = split_entries(roster.get("entries") or [], slot_ids, index)
            by_period = team.get("pointsByScoringPeriod") or {}
            total = by_period.get(str(week), team.get("totalPoints"))
            out.append({"roster_id": team["teamId"], "matchup_id": game.get("id"), "starters": starters,
                        "players_points": points,
                        "points": float(total) if isinstance(total, (int, float)) else 0.0})
    return out


def projection_filter(season: str, week: int, limit: int = 700) -> str:
    """X-Fantasy-Filter for every position's league-scored weekly projection
    (the most-owned `limit` players), with ownership."""
    return json.dumps({"players": {
        "filterSlotIds": {"value": fm_providers.ESPN_SLOT_IDS},
        "filterStatsForTopScoringPeriodIds": {"value": 2, "additionalValue": [
            "00%s" % season, "10%s" % season, "11%s%d" % (season, week), "01%s%d" % (season, week)]},
        "limit": limit,
        "sortPercOwned": {"sortPriority": 1, "sortAsc": False},
    }}, separators=(",", ":"))


def ownership_trend(payload: Any, players: Dict[str, dict]) -> List[dict]:
    """Players whose ownership across ESPN leagues is rising, as the
    trending-adds list the waiver score reads: [{player_id, count}], count
    in hundredths of a percentage point gained over the last week."""
    entries = payload.get("players") if isinstance(payload, dict) else payload
    if not isinstance(entries, list):
        return []
    index = PlayerIndex(players)
    out: List[dict] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        player = entry.get("player") if isinstance(entry.get("player"), dict) else entry
        change = (player.get("ownership") or {}).get("percentChange") if isinstance(player.get("ownership"), dict) else None
        if not isinstance(change, (int, float)) or isinstance(change, bool) or change <= 0:
            continue
        pid = index.resolve(player, add=False)
        if pid is not None:
            out.append({"player_id": pid, "count": int(round(change * 100))})
    out.sort(key=lambda row: (-row["count"], row["player_id"]))
    return out


def season_info(league_doc: dict, matchup_doc: Optional[dict]) -> dict:
    """Standings, the league's schedule by week and its playoff settings,
    for the playoff odds."""
    settings = (league_doc.get("settings") or {}).get("scheduleSettings") or {}
    periods = settings.get("matchupPeriods") or {}
    count = settings.get("matchupPeriodCount")
    last = None
    if isinstance(count, int) and count > 0:
        weeks = periods.get(str(count))
        last = max(weeks) if isinstance(weeks, list) and weeks else count
    standings = []
    for team in league_doc.get("teams") or []:
        record = ((team.get("record") or {}).get("overall")) if isinstance(team, dict) else None
        if isinstance(record, dict) and team.get("id") is not None:
            standings.append({"roster_id": team["id"], "wins": record.get("wins") or 0, "losses": record.get("losses") or 0,
                              "ties": record.get("ties") or 0, "points_for": record.get("pointsFor") or 0.0})
    schedule: Dict[str, List[List[Any]]] = {}
    for game in (matchup_doc or {}).get("schedule") or []:
        if not isinstance(game, dict):
            continue
        home, away = game.get("home") or {}, game.get("away") or {}
        if home.get("teamId") is None or away.get("teamId") is None:
            continue
        period = game.get("matchupPeriodId")
        for week in periods.get(str(period)) or ([period] if isinstance(period, int) else []):
            schedule.setdefault(str(week), []).append([home["teamId"], away["teamId"]])
    return {"regular_season_last_week": last, "playoff_teams": settings.get("playoffTeamCount"),
            "standings": standings, "schedule": schedule}


def host_points(payload: Any, week: int, players: Dict[str, dict], season: Optional[str]) -> Dict[str, float]:
    """League-scored weekly projections for kickers and team defenses."""
    points, _, _ = fm_providers.parse_espn(payload, week, players, season, defense_by_id=True)
    return {pid: value for pid, value in points.items()
            if str((players.get(pid) or {}).get("position") or "").upper() in HOST_POSITIONS}
