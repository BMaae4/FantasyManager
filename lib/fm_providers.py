"""Projection providers for fantasy_manager.

Sleeper's projection feed is the primary source: its raw projected stats
are scored with the league's own rules (lib/fm_analysis.py). A second
provider is normalised to the same shape, PPR points per Sleeper player id
and week, and used to:

* compare: flag players the two sources disagree on (default), and
* blend (--projections blend): a 50/50 consensus, applied to the
  league-scored Sleeper projection as a ratio of the two PPR totals.

Standard library only; parsing is pure so it can be tested offline.
"""

from __future__ import annotations

import json
from typing import Dict, List, Optional, Tuple

# ESPN's public fantasy API (unofficial): PPR league defaults, weekly
# projections. Players are matched by Sleeper's espn_id, then name + team.
ESPN_BASE = "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl"
ESPN_POSITIONS = {1: "QB", 2: "RB", 3: "WR", 4: "TE", 5: "K", 16: "DEF"}
ESPN_TEAMS = {
    1: "ATL", 2: "BUF", 3: "CHI", 4: "CIN", 5: "CLE", 6: "DAL", 7: "DEN", 8: "DET", 9: "GB", 10: "TEN",
    11: "IND", 12: "KC", 13: "LV", 14: "LAR", 15: "MIA", 16: "MIN", 17: "NE", 18: "NO", 19: "NYG", 20: "NYJ",
    21: "PHI", 22: "ARI", 23: "PIT", 24: "LAC", 25: "SF", 26: "SEA", 27: "TB", 28: "WAS", 29: "CAR",
    30: "JAX", 33: "BAL", 34: "HOU",
}
ESPN_SLOT_IDS = [0, 2, 4, 6, 17, 16]  # QB, RB, WR, TE, K, D/ST


def espn_url(season: str, week: int, base: str = ESPN_BASE) -> str:
    return "%s/seasons/%s/segments/0/leaguedefaults/3?view=kona_player_info&scoringPeriodId=%d" % (base, season, week)


def espn_filter(season: str, week: int, limit: int = 1500) -> str:
    return json.dumps({"players": {
        "filterSlotIds": {"value": ESPN_SLOT_IDS},
        "filterStatsForSourceIds": {"value": [1]},
        "filterStatsForSplitTypeIds": {"value": [1]},
        "filterStatsForExternalIds": {"value": [int(season)]},
        "filterStatsForTopScoringPeriodIds": {"value": 2, "additionalValue": ["11%s%d" % (season, week)]},
        "limit": limit,
        "sortPercOwned": {"sortPriority": 1, "sortAsc": False},
    }}, separators=(",", ":"))


def _norm(name: str) -> str:
    text = "".join(ch for ch in (name or "").lower() if ch.isalnum() or ch == " ")
    return " ".join(w for w in text.split() if w not in ("jr", "sr", "ii", "iii", "iv", "v"))


def parse_espn(payload, week: int, players: Dict[str, dict]) -> Tuple[Dict[str, float], int, List[str]]:
    """ESPN kona_player_info -> ({sleeper_pid: PPR points}, matched, unmatched names).

    Accepts the full response ({"players": [...]}) or the list itself; an
    entry is {"player": {...}} or the player object. Only weekly projections
    (statSourceId 1, statSplitTypeId 1) for `week` are used."""
    entries = payload.get("players") if isinstance(payload, dict) else payload
    if not isinstance(entries, list):
        return {}, 0, []
    by_espn = {str(v.get("espn_id")): pid for pid, v in players.items() if v.get("espn_id") not in (None, "")}
    by_name: Dict[Tuple[str, str, str], Optional[str]] = {}
    for pid, v in players.items():
        key = (_norm(v.get("full_name") or ""), str(v.get("team") or "").upper(), str(v.get("position") or "").upper())
        if key[0]:
            by_name[key] = None if key in by_name else pid
    out: Dict[str, float] = {}
    unmatched: List[str] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        player = entry.get("player") if isinstance(entry.get("player"), dict) else entry
        position = ESPN_POSITIONS.get(player.get("defaultPositionId"))
        if position is None:
            continue
        points = None
        for st in player.get("stats") or []:
            if (isinstance(st, dict) and st.get("statSourceId") == 1 and st.get("statSplitTypeId") == 1
                    and st.get("scoringPeriodId") == week and isinstance(st.get("appliedTotal"), (int, float))):
                points = float(st["appliedTotal"])
                break
        if points is None:
            continue
        team = ESPN_TEAMS.get(player.get("proTeamId"))
        if position == "DEF":
            pid = team if team in players else None
        else:
            pid = by_espn.get(str(player.get("id"))) or by_name.get((_norm(player.get("fullName") or ""), team or "", position))
        if pid is None:
            unmatched.append(str(player.get("fullName") or player.get("id")))
            continue
        out[pid] = round(points, 3)
    return out, len(out), unmatched


BLEND_WEIGHT = 0.5      # share of the second source in a blend
BLEND_LIMITS = (0.5, 1.5)


def blend_factor(primary_ppr: Optional[float], other_ppr: Optional[float]) -> Optional[float]:
    """Multiplier for the league-scored primary projection so that its PPR
    total moves halfway toward the other source's."""
    if primary_ppr is None or other_ppr is None or primary_ppr <= 0.5:
        return None
    factor = (1 - BLEND_WEIGHT) + BLEND_WEIGHT * (other_ppr / primary_ppr)
    return max(BLEND_LIMITS[0], min(BLEND_LIMITS[1], factor))


def disagrees(primary_ppr: float, other_ppr: float) -> bool:
    """A difference worth a look: 4+ points and 30%+ of the larger value."""
    diff = abs(primary_ppr - other_ppr)
    return diff >= 4.0 and diff >= 0.3 * max(primary_ppr, other_ppr)
