#!/usr/bin/env python3
"""Analysis engine for fantasy_manager.

Turns one bundle (league, rosters, users, matchups, players, projections,
activity, history, provenance) into one canonical report. lib/fm_app.py calls
it in-process; `fm_analysis.py --in BUNDLE --out REPORT` runs it on files.
Standard library only.

The engine never prints human readable output and never performs network
calls; rendering happens in lib/fm_app.py.
"""

from __future__ import annotations

import json
import math
import os
import random
import sys
from itertools import combinations
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_history  # noqa: E402

SCHEMA_VERSION = "1.4"

# Slots that do not start.
NON_STARTING_SLOTS = {"BN", "BE", "IR", "TAXI", "RESERVE"}

SLOT_ELIGIBILITY: Dict[str, Tuple[str, ...]] = {
    "QB": ("QB",),
    "RB": ("RB",),
    "WR": ("WR",),
    "TE": ("TE",),
    "K": ("K",),
    "DEF": ("DEF",),
    "DST": ("DEF",),
    "FLEX": ("RB", "WR", "TE"),
    "WRRB_FLEX": ("RB", "WR"),
    "WRRB_WRT": ("RB", "WR", "TE"),
    "REC_FLEX": ("WR", "TE"),
    "SUPER_FLEX": ("QB", "RB", "WR", "TE"),
    "IDP_FLEX": ("DL", "LB", "DB", "DE", "DT", "CB", "S", "ILB", "OLB"),
    "DL": ("DL", "DE", "DT"),
    "LB": ("LB", "ILB", "OLB"),
    "DB": ("DB", "CB", "S"),
    "DE": ("DE", "DL"),
    "DT": ("DT", "DL"),
    "CB": ("CB", "DB"),
    "S": ("S", "DB"),
}

# Players with these statuses are never offered as a normal start or pickup.
UNAVAILABLE_STATUSES = {
    "inactive",
    "retired",
    "suspended",
    "exempt",
    "non football injury",
    "non-football injury",
    "practice squad",
    "physically unable to perform",
    "pup",
    "injured reserve",
    "ir",
    "out",
    "did not report",
}

# Injury statuses that block a start outright versus ones that only add risk.
# Sleeper reports suspensions as injury_status "Sus".
BLOCKING_INJURY = {"out", "ir", "pup", "sus", "suspended", "doubtful", "na"}
RISK_INJURY = {"questionable", "doubtful", "limited participation", "did not participate"}

AGGREGATE_FALLBACK_FIELDS = ("pts_ppr", "pts_half_ppr", "pts_std")

# Scoring categories that belong to team defenses and kickers. When a league
# scores one of these and the projection feed has no matching stat, adding up
# the categories that *are* present undercounts that position by a varying
# amount (e.g. points-allowed tiers), so the whole position switches to the
# provider's projected total instead.
# Entries ending in "_" are prefixes; the rest are exact keys.
POSITION_SCORING_FAMILIES = {
    "DEF": ("pts_allow", "pts_allow_", "yds_allow", "yds_allow_", "def_", "sack", "int",
            "fum_rec", "safe", "blk_kick", "ff"),
    "K": ("fgm", "fgm_", "fga", "fga_", "fgmiss", "fgmiss_", "xpm", "xpmiss"),
}


def in_family(key: str, family: Tuple[str, ...]) -> bool:
    return any(key.startswith(entry) if entry.endswith("_") else key == entry for entry in family)

# Statuses that keep a player out beyond this week (used for future weeks).
LONG_TERM_UNAVAILABLE = {
    "inactive", "retired", "suspended", "exempt", "non football injury",
    "non-football injury", "practice squad", "physically unable to perform", "pup",
    "injured reserve", "ir", "did not report",
}

# Minimum projected gain per window week, for each side, before a trade
# framework is shown.
MIN_TRADE_GAIN = 0.5

# Schedule statuses that mean a game has kicked off.
STARTED_GAME_STATUSES = {"in_game", "complete"}

# Win-probability simulation: spread of a starter's score around the
# projection (points, one standard deviation) for a typical starter, used
# until this season's history has enough games; scaled by sqrt(projection /
# reference projection).
DEFAULT_SPREAD = {"QB": 6.5, "RB": 6.5, "WR": 6.5, "TE": 5.0, "K": 4.0, "DEF": 5.5}
SPREAD_REFERENCE = {"QB": 18.0, "RB": 12.0, "WR": 12.0, "TE": 9.0, "K": 8.0, "DEF": 7.0}
MIN_HISTORY_GAMES = 30
# A player's own spread needs at least this many games, and is shrunk
# toward the position estimate as if that estimate were worth this many.
MIN_PLAYER_GAMES = 3
PLAYER_SPREAD_PRIOR_GAMES = 6
SIMULATIONS = 10000

WAIVER_WEIGHTS = {
    "roster_improvement": 0.40,
    "rest_of_season_value": 0.25,
    "opportunity": 0.15,
    "add_trend": 0.10,
    "schedule_fit": 0.10,
}


def r2(value: Optional[float]) -> Optional[float]:
    if value is None:
        return None
    return round(float(value) + 0.0, 2)


def lower(value) -> str:
    return str(value).strip().lower() if value is not None else ""


# ---------------------------------------------------------------------------
# Min cost max flow (exact maximum weight assignment of players to slots)
# ---------------------------------------------------------------------------
class MinCostMaxFlow:
    def __init__(self, nodes: int) -> None:
        self.nodes = nodes
        self.graph: List[List[List[int]]] = [[] for _ in range(nodes)]

    def add_edge(self, u: int, v: int, cap: int, cost: int) -> None:
        self.graph[u].append([v, cap, cost, len(self.graph[v])])
        self.graph[v].append([u, 0, -cost, len(self.graph[u]) - 1])

    def run(self, source: int, sink: int) -> Tuple[int, int]:
        flow = 0
        cost = 0
        inf = float("inf")
        while True:
            dist = [inf] * self.nodes
            in_queue = [False] * self.nodes
            prev_node = [-1] * self.nodes
            prev_edge = [-1] * self.nodes
            dist[source] = 0
            queue = [source]
            in_queue[source] = True
            while queue:
                u = queue.pop(0)
                in_queue[u] = False
                for idx, edge in enumerate(self.graph[u]):
                    v, cap, ecost, _ = edge
                    if cap > 0 and dist[u] + ecost < dist[v]:
                        dist[v] = dist[u] + ecost
                        prev_node[v] = u
                        prev_edge[v] = idx
                        if not in_queue[v]:
                            in_queue[v] = True
                            queue.append(v)
            if dist[sink] == inf:
                break
            push = inf
            v = sink
            while v != source:
                edge = self.graph[prev_node[v]][prev_edge[v]]
                push = min(push, edge[1])
                v = prev_node[v]
            v = sink
            while v != source:
                edge = self.graph[prev_node[v]][prev_edge[v]]
                edge[1] -= push
                self.graph[v][edge[3]][1] += push
                v = prev_node[v]
            flow += push
            cost += push * dist[sink]
        return flow, cost


def assign_slots(
    slots: Sequence[str],
    candidates: Sequence[str],
    weight_of: Dict[Tuple[int, str], int],
) -> Dict[int, str]:
    """Exact maximum-weight assignment: slot index -> player id (or absent)."""
    n_slots = len(slots)
    n_players = len(candidates)
    if n_slots == 0 or n_players == 0:
        return {}
    source = 0
    sink = n_slots + n_players + 1
    mcmf = MinCostMaxFlow(sink + 1)
    for i in range(n_slots):
        mcmf.add_edge(source, 1 + i, 1, 0)
    for j in range(n_players):
        mcmf.add_edge(1 + n_slots + j, sink, 1, 0)
    edge_refs: List[Tuple[int, int, int]] = []
    for i in range(n_slots):
        for j, pid in enumerate(candidates):
            weight = weight_of.get((i, pid))
            if weight is None:
                continue
            node_u = 1 + i
            edge_index = len(mcmf.graph[node_u])
            mcmf.add_edge(node_u, 1 + n_slots + j, 1, -weight)
            edge_refs.append((node_u, edge_index, j))
    mcmf.run(source, sink)
    assignment: Dict[int, str] = {}
    for node_u, edge_index, j in edge_refs:
        edge = mcmf.graph[node_u][edge_index]
        if edge[1] == 0:  # saturated -> used
            assignment[node_u - 1] = candidates[j]
    return assignment


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------
class Analyzer:
    def __init__(self, bundle: dict) -> None:
        self.bundle = bundle
        self.config = bundle.get("config") or {}
        self.provenance = bundle.get("provenance") or {}
        self.warnings: List[str] = list(bundle.get("warnings") or [])
        self.league = bundle.get("league") or {}
        self.rosters = [r for r in (bundle.get("rosters") or []) if isinstance(r, dict)]
        self.users = [u for u in (bundle.get("users") or []) if isinstance(u, dict)]
        self.matchups = [m for m in (bundle.get("matchups") or []) if isinstance(m, dict)]
        self.players: Dict[str, dict] = bundle.get("players") or {}
        self.trending = bundle.get("trending_add") or []
        self.scoring_settings = self.league.get("scoring_settings") or {}
        self.roster_positions = [
            str(p) for p in (self.league.get("roster_positions") or []) if p is not None
        ]
        self.starting_slots = [
            p for p in self.roster_positions if p.upper() not in NON_STARTING_SLOTS
        ]
        self.my_roster_id = self.config.get("my_roster_id")
        self.threshold = float(self.config.get("churn_threshold") or 0.0)
        self.fairness = float(self.config.get("fairness") or 0.10)
        self.top_n = int(self.config.get("top_n") or 10)

        self.projection_points: Dict[str, float] = {}
        # week_points[0] is this week; later entries are the future window.
        self.week_points: List[Dict[str, float]] = [self.projection_points]
        self.window_weeks: List[int] = []
        self._use_custom = False
        self._aggregate_field_used: Optional[str] = None
        self.projection_stats: Dict[str, dict] = {}
        self.week_stats: List[Dict[str, dict]] = [self.projection_stats]
        self.scoring_mode = "unknown"
        self.scoring_source = "unknown"
        self.unsupported_scoring_keys: List[str] = []
        self._optimize_cache: Dict[Tuple[str, ...], Tuple[float, Dict[int, str]]] = {}

        self.rostered: Dict[str, int] = {}
        for roster in self.rosters:
            for pid in self._roster_all_players(roster):
                self.rostered[pid] = roster.get("roster_id")

        self.position_fallback: Dict[str, str] = {}
        self._init_locks()

    # -- locks (games already started) -----------------------------------
    def _init_locks(self) -> None:
        """Work out which players' games have kicked off this week.

        Sources, in order: the game schedule (status per team), live points
        from the week's matchups, and players named with --locked.
        """
        week = str(self.config.get("week"))
        provenance = self.provenance or {}
        self.schedule_available = bool(provenance.get("schedule_available"))
        self.team_game_status: Dict[str, str] = {}
        for game in self.bundle.get("schedule") or []:
            if not isinstance(game, dict) or str(game.get("week")) != week:
                continue
            status = lower(game.get("status"))
            for side in ("home", "away"):
                team = game.get(side)
                if team:
                    self.team_game_status[str(team).upper()] = status

        self.live_points: Dict[str, float] = {}
        for entry in self.matchups:
            for pid, value in (entry.get("players_points") or {}).items():
                if isinstance(value, (int, float)):
                    self.live_points[str(pid)] = float(value)

        self.manual_locks: set = set()
        wanted = [lower(item) for item in (self.config.get("locked") or []) if item]
        unmatched = []
        if wanted:
            by_name: Dict[str, List[str]] = {}
            for pid, info in self.players.items():
                if isinstance(info, dict) and info.get("full_name"):
                    by_name.setdefault(lower(info["full_name"]), []).append(str(pid))
            for item in wanted:
                if item in by_name:
                    self.manual_locks.update(by_name[item])
                elif item.upper() in self.players or item in self.players:
                    self.manual_locks.add(item.upper() if item.upper() in self.players else item)
                else:
                    unmatched.append(item)
        if unmatched:
            self.warn("--locked entries not matched to any player: %s." % ", ".join(unmatched))

        if self.schedule_available:
            self.lock_source = "game schedule + live points"
        else:
            self.lock_source = "live points only (schedule unavailable)"
        if self.manual_locks:
            self.lock_source += " + --locked"

    def is_locked(self, pid: Optional[str]) -> bool:
        if pid is None:
            return False
        pid = str(pid)
        if pid in self.manual_locks:
            return True
        if self.live_points.get(pid, 0.0) != 0.0:
            return True
        if self.schedule_available:
            team = self.player(pid).get("team")
            if team and self.team_game_status.get(str(team).upper()) in STARTED_GAME_STATUSES:
                return True
        return False

    # -- helpers ----------------------------------------------------------
    def warn(self, message: str) -> None:
        if message not in self.warnings:
            self.warnings.append(message)

    @staticmethod
    def _roster_all_players(roster: dict) -> List[str]:
        players = roster.get("players") or []
        return [str(p) for p in players if p not in (None, "", "0")]

    def roster_active_players(self, roster: dict) -> List[str]:
        """Players usable this week: roster minus IR/taxi designations."""
        blocked = set()
        for key in ("reserve", "taxi"):
            for pid in roster.get(key) or []:
                if pid not in (None, "", "0"):
                    blocked.add(str(pid))
        return [p for p in self._roster_all_players(roster) if p not in blocked]

    def player(self, pid: str) -> dict:
        info = self.players.get(str(pid))
        if isinstance(info, dict):
            return info
        return {}

    def player_name(self, pid: str) -> str:
        info = self.player(pid)
        name = info.get("full_name")
        if name:
            return str(name)
        return "unknown player %s" % pid

    def player_positions(self, pid: str) -> Tuple[str, ...]:
        info = self.player(pid)
        positions = info.get("fantasy_positions") or []
        result = [str(p).upper() for p in positions if p]
        if not result and info.get("position"):
            result = [str(info["position"]).upper()]
        return tuple(result)

    def primary_position(self, pid: str) -> Optional[str]:
        info = self.player(pid)
        if info.get("position"):
            return str(info["position"]).upper()
        positions = self.player_positions(pid)
        return positions[0] if positions else None

    def points(self, pid: str, w: int = 0) -> float:
        """Projected points in window week `w` (0 = this week)."""
        return float(self.week_points[w].get(str(pid), 0.0))

    def has_projection(self, pid: str, w: int = 0) -> bool:
        return str(pid) in self.week_points[w]

    @property
    def n_weeks(self) -> int:
        return len(self.week_points)

    @property
    def has_window(self) -> bool:
        return len(self.week_points) > 1

    def window_points(self, pid: str) -> float:
        """Raw projected points summed over every week in the window."""
        return sum(self.points(pid, w) for w in range(self.n_weeks))

    def startable_in(self, pid: str, w: int) -> bool:
        """This week: the full availability check. Future weeks: only
        long-term statuses rule a player out; a one-week injury shows up as a
        low or missing projection for that week instead."""
        if w == 0:
            return self.availability(pid)[0]
        info = self.player(pid)
        if not info or info.get("active") is False:
            return False
        return lower(info.get("status")) not in LONG_TERM_UNAVAILABLE

    def availability(self, pid: str) -> Tuple[bool, List[str]]:
        """(startable, notes).  Missing data is reported, never invented."""
        info = self.player(pid)
        notes: List[str] = []
        if not info:
            return False, ["not in player database"]
        status = lower(info.get("status"))
        injury = lower(info.get("injury_status"))
        startable = True
        if info.get("active") is False:
            startable = False
            notes.append("marked inactive")
        if status and status not in ("active", "none"):
            notes.append("status %s" % info.get("status"))
            if status in UNAVAILABLE_STATUSES:
                startable = False
        if injury:
            notes.append("injury %s" % info.get("injury_status"))
            if injury in BLOCKING_INJURY:
                startable = False
        practice = info.get("practice_participation")
        if practice:
            notes.append("practice %s" % practice)
        if not self.has_projection(pid):
            notes.append("no projection")
        return startable, notes

    # -- scoring ----------------------------------------------------------
    def calculate_league_scoring(self) -> None:
        projections = self.bundle.get("projections") or []
        stats_keys_seen = set()
        records = 0
        for record in projections:
            if not isinstance(record, dict):
                continue
            pid = record.get("player_id")
            stats = record.get("stats")
            if pid is None or not isinstance(stats, dict):
                continue
            pid = str(pid)
            self.projection_stats[pid] = stats
            stats_keys_seen.update(stats.keys())
            records += 1
        if records == 0:
            raise SystemExit("projection feed contained no usable records")

        use_custom = bool(self.scoring_settings) and bool(
            set(self.scoring_settings.keys()) & stats_keys_seen
        )
        self._use_custom = use_custom
        if use_custom:
            self.scoring_mode = "league scoring_settings"
            self.scoring_source = "league.scoring_settings x projected stats"
            for pid, stats in self.projection_stats.items():
                total = 0.0
                for key, value in stats.items():
                    weight = self.scoring_settings.get(key)
                    if weight is None or not isinstance(value, (int, float)):
                        continue
                    if not isinstance(weight, (int, float)):
                        continue
                    total += float(value) * float(weight)
                self.projection_points[pid] = total
            unsupported = sorted(
                key
                for key, weight in self.scoring_settings.items()
                if isinstance(weight, (int, float))
                and weight != 0
                and key not in stats_keys_seen
            )
            self.unsupported_scoring_keys = unsupported
            self._apply_position_fallback(unsupported, stats_keys_seen)
            if unsupported:
                message = (
                    "%d league scoring categories have no matching projection stat: %s."
                    % (len(unsupported), ", ".join(unsupported[:25]))
                )
                if self.position_fallback:
                    message += (
                        " %s use Sleeper's projected total (%s, Sleeper default scoring) "
                        "instead of a partial league score; the rest are excluded."
                        % (
                            " and ".join(sorted(self.position_fallback)),
                            ", ".join(sorted(set(self.position_fallback.values()))),
                        )
                    )
                else:
                    message += " They are excluded."
                self.warn(message)
        else:
            field = None
            for candidate in AGGREGATE_FALLBACK_FIELDS:
                if candidate in stats_keys_seen:
                    field = candidate
                    break
            if field is None:
                raise SystemExit(
                    "projections contain neither league scoring categories nor an "
                    "aggregate points field"
                )
            self._aggregate_field_used = field
            self.scoring_mode = "provider aggregate fallback (%s)" % field
            self.scoring_source = "projection field %s (league scoring not applied)" % field
            for pid, stats in self.projection_stats.items():
                value = stats.get(field)
                if isinstance(value, (int, float)):
                    self.projection_points[pid] = float(value)
            self.warn(
                "League scoring settings could not be matched to projection stats; "
                "using provider aggregate field '%s' as a labelled fallback." % field
            )

    def score_stats(self, pid: str, stats: dict) -> Optional[float]:
        """Score one projected stat line with the rules chosen for this week
        (league scoring, per-position fallback, or provider aggregate)."""
        position = self.primary_position(pid)
        field = None
        if not self._use_custom:
            field = self._aggregate_field_used
        elif position in self.position_fallback:
            field = self.position_fallback[position]
        if field is not None:
            value = stats.get(field)
            if isinstance(value, (int, float)):
                return float(value)
            if not self._use_custom:
                return None
        total = 0.0
        for key, value in stats.items():
            weight = self.scoring_settings.get(key)
            if isinstance(weight, (int, float)) and isinstance(value, (int, float)):
                total += float(value) * float(weight)
        return total

    def score_future_weeks(self) -> None:
        future = self.bundle.get("future_projections") or {}
        this_week = self.config.get("week")
        self.window_weeks = [int(this_week)] if this_week is not None else [0]
        weeks = sorted(int(w) for w in future.keys() if str(w).isdigit())
        for week in weeks:
            points: Dict[str, float] = {}
            stats_by_pid: Dict[str, dict] = {}
            for record in future.get(str(week)) or []:
                if not isinstance(record, dict) or not isinstance(record.get("stats"), dict):
                    continue
                pid = record.get("player_id")
                if pid is None:
                    continue
                stats_by_pid[str(pid)] = record["stats"]
                value = self.score_stats(str(pid), record["stats"])
                if value is not None:
                    points[str(pid)] = value
            if points:
                self.week_points.append(points)
                self.week_stats.append(stats_by_pid)
                self.window_weeks.append(week)

    def _aggregate_field(self, stats_keys_seen: set) -> Optional[str]:
        rec = self.scoring_settings.get("rec")
        preferred = {1: "pts_ppr", 0.5: "pts_half_ppr", 0: "pts_std"}.get(
            float(rec) if isinstance(rec, (int, float)) else 1.0, "pts_ppr"
        )
        for field in (preferred,) + AGGREGATE_FALLBACK_FIELDS:
            if field in stats_keys_seen:
                return field
        return None

    def _apply_position_fallback(self, unsupported: List[str], stats_keys_seen: set) -> None:
        field = self._aggregate_field(stats_keys_seen)
        if field is None:
            return
        for position, prefixes in POSITION_SCORING_FAMILIES.items():
            if not any(in_family(key, prefixes) for key in unsupported):
                continue
            switched = 0
            for pid, stats in self.projection_stats.items():
                if self.primary_position(pid) != position:
                    continue
                value = stats.get(field)
                if isinstance(value, (int, float)):
                    self.projection_points[pid] = float(value)
                    switched += 1
            if switched:
                self.position_fallback[position] = field

    # -- lineup optimisation ---------------------------------------------
    def eligible(self, slot: str, pid: str) -> bool:
        allowed = SLOT_ELIGIBILITY.get(slot.upper())
        if allowed is None:
            return False
        return bool(set(self.player_positions(pid)) & set(allowed))

    def build_weights(
        self,
        slots: Sequence[str],
        candidates: Sequence[str],
        incumbents: Optional[Dict[int, str]] = None,
        w: int = 0,
    ) -> Dict[Tuple[int, str], int]:
        incumbents = incumbents or {}
        order = sorted(candidates, key=lambda p: (-self.points(p, w), str(p)))
        tiebreak = {pid: len(order) - idx for idx, pid in enumerate(order)}
        weights: Dict[Tuple[int, str], int] = {}
        for i, slot in enumerate(slots):
            for pid in candidates:
                if not self.eligible(slot, pid):
                    continue
                points_milli = int(round(self.points(pid, w) * 1000))
                incumbent = 1 if incumbents.get(i) == pid else 0
                floor_milli = 0  # no reliable floor projection source available
                weights[(i, pid)] = (
                    points_milli * 10 ** 12
                    + incumbent * 10 ** 10
                    + floor_milli * 10 ** 4
                    + tiebreak[pid]
                )
        return weights

    def optimize(
        self,
        player_ids: Iterable[str],
        slots: Optional[Sequence[str]] = None,
        incumbents: Optional[Dict[int, str]] = None,
        filter_available: bool = True,
        w: int = 0,
    ) -> Tuple[float, Dict[int, str]]:
        slots = list(slots if slots is not None else self.starting_slots)
        candidates = sorted({str(p) for p in player_ids})
        if filter_available:
            candidates = [p for p in candidates if self.startable_in(p, w)]
        cache_key = tuple(
            ["w%d" % w, "|".join(slots)] + candidates
            + ["inc:%s" % sorted((incumbents or {}).items())]
        )
        cached = self._optimize_cache.get(cache_key)
        if cached is not None:
            return cached
        weights = self.build_weights(slots, candidates, incumbents, w)
        assignment = assign_slots(slots, candidates, weights)
        total = sum(self.points(pid, w) for pid in assignment.values())
        result = (total, assignment)
        self._optimize_cache[cache_key] = result
        return result

    def optimize_with_fixed(
        self,
        player_ids: Iterable[str],
        fixed: Dict[int, str],
        incumbents: Optional[Dict[int, str]] = None,
    ) -> Tuple[float, Dict[int, str]]:
        """Optimise only the open slots: `fixed` (slot index -> player) stays
        as is, and players whose games have started cannot be moved in."""
        free_idx = [i for i in range(len(self.starting_slots)) if i not in fixed]
        fixed_ids = set(fixed.values())
        candidates = [p for p in player_ids if p not in fixed_ids and not self.is_locked(p)]
        sub_incumbents = {
            k: incumbents[i] for k, i in enumerate(free_idx) if incumbents and i in incumbents
        }
        total, sub = self.optimize(
            candidates,
            slots=[self.starting_slots[i] for i in free_idx],
            incumbents=sub_incumbents,
        )
        assignment = dict(fixed)
        for k, pid in sub.items():
            assignment[free_idx[k]] = pid
        return total + sum(self.points(pid) for pid in fixed.values()), assignment

    def window_value(
        self,
        player_ids: Iterable[str],
        fixed: Optional[Dict[int, str]] = None,
        use_locks: bool = False,
    ) -> Tuple[float, List[float]]:
        """Optimal starting points summed over the window. Week 0 honours
        locks when `use_locks` (the manager's own roster); later weeks are
        open. Returns (window total, per-week totals)."""
        players = list(player_ids)
        if use_locks:
            first, _ = self.optimize_with_fixed(players, fixed or {})
        else:
            first, _ = self.optimize(players)
        totals = [first]
        for w in range(1, self.n_weeks):
            total, _ = self.optimize(players, w=w)
            totals.append(total)
        return sum(totals), totals

    def locked_starters(self, roster: dict) -> Dict[int, str]:
        return {i: pid for i, pid in self.current_lineup(roster).items() if self.is_locked(pid)}

    def current_lineup(self, roster: dict) -> Dict[int, str]:
        starters = roster.get("starters") or []
        lineup: Dict[int, str] = {}
        for index, _slot in enumerate(self.starting_slots):
            if index >= len(starters):
                continue
            pid = starters[index]
            if pid in (None, "", "0", 0):
                continue
            lineup[index] = str(pid)
        return lineup

    def player_ref(self, pid: Optional[str]) -> Optional[dict]:
        if pid is None:
            return None
        info = self.player(pid)
        known = bool(info)
        return {
            "player_id": str(pid),
            "name": self.player_name(pid),
            "position": self.primary_position(pid),
            "team": info.get("team"),
            "points": r2(self.points(pid)) if self.has_projection(pid) else None,
            "status": info.get("status"),
            "injury_status": info.get("injury_status"),
            "in_player_database": known,
        }

    def analyze_lineup(self, roster: dict) -> dict:
        usable = self.roster_active_players(roster)
        current = self.current_lineup(roster)
        current_points = sum(self.points(pid) for pid in current.values())

        for pid in current.values():
            if not self.player(pid):
                self.warn("Current starter %s is not in the player database." % pid)
            elif not self.has_projection(pid):
                self.warn(
                    "No projection for current starter %s; counted as 0.0."
                    % self.player_name(pid)
                )

        valid_incumbents = {
            index: pid
            for index, pid in current.items()
            if pid in set(usable)
            and self.eligible(self.starting_slots[index], pid)
            and self.availability(pid)[0]
        }
        fixed = self.locked_starters(roster)
        optimal_points, optimal = self.optimize_with_fixed(
            usable, fixed, incumbents=valid_incumbents
        )

        recommended_ids = set(optimal.values())
        current_ids = set(current.values())
        slots_out = []
        for index, slot in enumerate(self.starting_slots):
            cur = current.get(index)
            rec = optimal.get(index)
            cur_points = self.points(cur) if cur else 0.0
            rec_points = self.points(rec) if rec else 0.0
            gain = rec_points - cur_points
            if index in fixed:
                action = "LOCKED"
            elif cur == rec and rec is not None:
                action = "KEEP"
            elif rec is None and cur is None:
                action = "EMPTY SLOT"
            elif rec is None:
                action = "BENCH"
            elif cur is None:
                action = "START"
            elif rec in current_ids:
                action = "MOVE"
            else:
                action = "START"
            slots_out.append(
                {
                    "index": index,
                    "slot": slot,
                    "current": self.player_ref(cur),
                    "recommended": self.player_ref(rec),
                    "action": action,
                    "gain": r2(gain),
                    "below_threshold": bool(
                        action not in ("KEEP", "LOCKED") and abs(gain) < self.threshold
                    ),
                }
            )

        if not optimal and self.starting_slots:
            self.warn("No eligible players could be assigned to any starting slot.")
        for index, slot in enumerate(self.starting_slots):
            if index not in optimal:
                self.warn("No eligible available player for slot %s (index %d)." % (slot, index))

        bench = []
        for pid in sorted(usable, key=lambda p: (-self.points(p), str(p))):
            if pid in recommended_ids:
                continue
            bench.append(self.player_ref(pid))

        risk = []
        for pid in sorted(set(usable) | current_ids, key=lambda p: (-self.points(p), str(p))):
            if self.is_locked(pid):
                continue  # already played this week: availability is moot
            info = self.player(pid)
            startable, notes = self.availability(pid)
            injury = lower(info.get("injury_status"))
            status = lower(info.get("status"))
            flagged = (
                not startable
                or injury in RISK_INJURY
                or (status and status not in ("active", "none"))
                or not info
            )
            if not flagged:
                continue
            risk.append(
                {
                    "player_id": pid,
                    "name": self.player_name(pid),
                    "position": self.primary_position(pid),
                    "status": info.get("status"),
                    "injury_status": info.get("injury_status"),
                    "practice_participation": info.get("practice_participation"),
                    "injury_notes": info.get("injury_notes"),
                    "excluded_from_recommendations": not startable,
                    "note": "; ".join(notes) if notes else None,
                }
            )

        actions = [s for s in slots_out if s["action"] not in ("KEEP", "LOCKED")]
        locked_bench = [
            pid for pid in usable
            if pid not in fixed.values() and self.is_locked(pid) and self.availability(pid)[0]
        ]
        return {
            "locks": {
                "source": self.lock_source,
                "locked_starters": [self.player_ref(pid) for _, pid in sorted(fixed.items())],
                "locked_bench": [self.player_ref(pid) for pid in sorted(locked_bench)],
            },
            "current_points": r2(current_points),
            "optimal_points": r2(optimal_points),
            "gain": r2(optimal_points - current_points),
            "churn_threshold": self.threshold,
            "slots": slots_out,
            "actions": actions,
            "optional_actions": [s for s in actions if s["below_threshold"]],
            "bench": bench,
            "risk": risk,
        }

    # -- matchup ----------------------------------------------------------
    def team_name(self, roster_id) -> Optional[str]:
        roster = self.roster_by_id(roster_id)
        if roster is None:
            return None
        owner_id = roster.get("owner_id")
        for user in self.users:
            if user.get("user_id") == owner_id:
                metadata = user.get("metadata") or {}
                return metadata.get("team_name") or user.get("display_name")
        return None

    def roster_by_id(self, roster_id) -> Optional[dict]:
        for roster in self.rosters:
            if roster.get("roster_id") == roster_id:
                return roster
        return None

    def analyze_matchup(self) -> Optional[dict]:
        if not self.matchups:
            return None
        mine = None
        for entry in self.matchups:
            if entry.get("roster_id") == self.my_roster_id:
                mine = entry
                break
        if mine is None:
            self.warn("Roster %s is missing from the week's matchups." % self.my_roster_id)
            return None
        matchup_id = mine.get("matchup_id")
        opponent = None
        if matchup_id is not None:
            for entry in self.matchups:
                if entry is mine:
                    continue
                if entry.get("matchup_id") == matchup_id:
                    opponent = entry
                    break
        if opponent is None:
            self.warn("No opponent found for matchup %s (bye or incomplete data)." % matchup_id)

        def projected(entry: Optional[dict]) -> Optional[float]:
            if entry is None:
                return None
            starters = [str(p) for p in (entry.get("starters") or []) if p not in (None, "", "0", 0)]
            if not starters:
                return None
            return sum(self.points(pid) for pid in starters)

        def projected_final(entry: Optional[dict]) -> Optional[float]:
            # Actual points for starters whose games have started, projection
            # for the rest: the live picture of where the week will end up.
            if entry is None:
                return None
            starters = [str(p) for p in (entry.get("starters") or []) if p not in (None, "", "0", 0)]
            if not starters:
                return None
            live = entry.get("players_points") or {}
            total = 0.0
            for pid in starters:
                if self.is_locked(pid):
                    value = live.get(pid, self.live_points.get(pid, 0.0))
                    total += float(value) if isinstance(value, (int, float)) else 0.0
                else:
                    total += self.points(pid)
            return total

        my_projected = projected(mine)
        opp_projected = projected(opponent)
        differential = None
        if my_projected is not None and opp_projected is not None:
            differential = my_projected - opp_projected
        my_final = projected_final(mine)
        opp_final = projected_final(opponent)
        final_differential = None
        if my_final is not None and opp_final is not None:
            final_differential = my_final - opp_final
        return {
            "matchup_id": matchup_id,
            "my_team": self.team_name(self.my_roster_id),
            "opponent_roster_id": opponent.get("roster_id") if opponent else None,
            "opponent_team": self.team_name(opponent.get("roster_id")) if opponent else None,
            "my_projected": r2(my_projected),
            "opponent_projected": r2(opp_projected),
            "differential": r2(differential),
            "my_projected_final": r2(my_final),
            "opponent_projected_final": r2(opp_final),
            "final_differential": r2(final_differential),
            "my_points": r2(mine.get("points")) if isinstance(mine.get("points"), (int, float)) else None,
            "opponent_points": r2(opponent.get("points")) if opponent and isinstance(opponent.get("points"), (int, float)) else None,
            "note": (
                "Projection-only optimisation: correlation, game script and "
                "opponent defensive matchups are not modelled."
            ),
        }

    # -- win probability --------------------------------------------------
    def score_spread(self, pid: str) -> float:
        """Spread of this player's score: the position estimate (this
        season's misses, or a typical value) scaled by projection, blended
        with the player's own misses when he has enough games."""
        position = self.primary_position(pid) or "?"
        base = DEFAULT_SPREAD.get(position, 6.0)
        acc = (getattr(self, "history_accuracy", None) or {}).get(position)
        if acc and (acc.get("n") or 0) >= MIN_HISTORY_GAMES and acc.get("sd"):
            base = float(acc["sd"])
        ref = SPREAD_REFERENCE.get(position, 10.0)
        scale = math.sqrt(max(self.points(pid), 0.5) / ref)
        prior = base * min(1.6, max(0.4, scale))
        own = (getattr(self, "history_player_misses", None) or {}).get(pid)
        if not own or len(own) < MIN_PLAYER_GAMES:
            return prior
        mean = sum(own) / len(own)
        var = sum((e - mean) ** 2 for e in own) / (len(own) - 1)
        k, dof = PLAYER_SPREAD_PRIOR_GAMES, len(own) - 1
        return math.sqrt((k * prior * prior + dof * var) / (k + dof))

    def simulate_matchup(self, matchup: dict, lineup: dict) -> Optional[dict]:
        """Monte Carlo win probability for the current and recommended
        lineups against the opponent's current starters."""
        mine = next((m for m in self.matchups if m.get("roster_id") == self.my_roster_id), None)
        opponent = next((m for m in self.matchups if m is not mine and mine is not None
                         and m.get("matchup_id") == mine.get("matchup_id")), None)
        if mine is None or opponent is None:
            return None

        def starters(entry: dict) -> List[str]:
            return [str(p) for p in (entry.get("starters") or []) if p not in (None, "", "0", 0)]

        current = starters(mine)
        recommended = [s["recommended"]["player_id"] for s in lineup["slots"] if s.get("recommended")]
        theirs = starters(opponent)
        if not recommended or not theirs:
            return None
        my_roster = self.roster_by_id(self.my_roster_id) or {}
        bench = [p for p in self.roster_active_players(my_roster)
                 if p not in recommended and self.has_projection(p) and self.availability(p)[0] and not self.is_locked(p)]

        fixed: Dict[str, float] = {}
        for entry in (mine, opponent):
            live = entry.get("players_points") or {}
            for pid in starters(entry):
                if self.is_locked(pid):
                    value = live.get(pid, self.live_points.get(pid, 0.0))
                    fixed[pid] = float(value) if isinstance(value, (int, float)) else 0.0

        rng = random.Random("%s-%s-%s" % (self.config.get("league_id"), self.config.get("season"), self.config.get("week")))
        n = SIMULATIONS
        draws: Dict[str, List[float]] = {}
        for pid in sorted(set(current) | set(recommended) | set(theirs) | set(bench)):
            if pid in fixed:
                draws[pid] = [fixed[pid]] * n
                continue
            mean, sd = self.points(pid), self.score_spread(pid)
            draws[pid] = [max(0.0, mean + sd * rng.gauss(0.0, 1.0)) for _ in range(n)]

        def totals(pids: Sequence[str]) -> List[float]:
            out = [0.0] * n
            for pid in pids:
                d = draws[pid]
                for i in range(n):
                    out[i] += d[i]
            return out

        opp_totals = totals(theirs)

        def win_pct(mine_totals: Sequence[float]) -> float:
            wins = sum(1.0 if a > b else 0.5 if a == b else 0.0 for a, b in zip(mine_totals, opp_totals))
            return round(100.0 * wins / n, 1)

        def spread_of(values: Sequence[float]) -> dict:
            ordered = sorted(values)
            return {"p10": r2(ordered[int(0.1 * n)]), "p50": r2(ordered[int(0.5 * n)]), "p90": r2(ordered[int(0.9 * n)])}

        rec_totals = totals(recommended)
        rec_pct = win_pct(rec_totals)
        moves = []
        slot_of = {s["recommended"]["player_id"]: s for s in lineup["slots"] if s.get("recommended")}
        for out_pid in recommended:
            slot = slot_of[out_pid]
            if slot["action"] == "LOCKED" or out_pid in fixed:
                continue
            for in_pid in bench:
                if not self.eligible(slot["slot"], in_pid):
                    continue
                d_out, d_in = draws[out_pid], draws[in_pid]
                pct = win_pct([rec_totals[i] - d_out[i] + d_in[i] for i in range(n)])
                if pct - rec_pct >= 1.0:
                    moves.append({"slot": slot["slot"], "out": self.player_ref(out_pid), "in": self.player_ref(in_pid),
                                  "win_pct": pct, "win_gain": round(pct - rec_pct, 1),
                                  "points_change": r2(self.points(in_pid) - self.points(out_pid))})
        moves.sort(key=lambda m: (-m["win_gain"], m["in"]["player_id"]))
        hist = getattr(self, "history_accuracy", None) or {}
        from_history = sorted(p for p, a in hist.items() if a and (a.get("n") or 0) >= MIN_HISTORY_GAMES and a.get("sd"))
        spreads = {}
        for pos in sorted({self.primary_position(p) or "?" for p in draws}):
            acc = hist.get(pos)
            spreads[pos] = r2(float(acc["sd"]) if pos in from_history else DEFAULT_SPREAD.get(pos, 6.0))
        return {
            "current_lineup_pct": win_pct(totals(current)) if current else None,
            "recommended_lineup_pct": rec_pct,
            "simulations": n,
            "my_range": spread_of(rec_totals),
            "opponent_range": spread_of(opp_totals),
            "fixed_players": len(fixed),
            "spread_source": ("this season's projection misses for " + ", ".join(from_history)
                              + ("; typical spreads for the rest" if len(from_history) < len(spreads) else "")
                              if from_history else "typical spreads (not enough history yet)"),
            "spreads": spreads,
            "moves": moves[:3],
            "note": ("Each starter scores around their projection with a spread by position (normal, floored at 0, "
                     "wider for bigger projections); players whose game has started count at their current points. "
                     "Players are treated as independent: same-game correlation is not modelled."),
        }

    # -- waivers ----------------------------------------------------------
    def league_positions(self) -> List[str]:
        positions = set()
        for slot in self.starting_slots:
            positions.update(SLOT_ELIGIBILITY.get(slot.upper(), ()))
        return sorted(positions)

    def replacement_levels(self) -> Dict[str, float]:
        num_teams = len(self.rosters) or int(self.league.get("total_rosters") or 0) or 1
        # A dedicated slot counts fully for its position; a multi-position
        # slot (FLEX, SUPER_FLEX, IDP_FLEX...) is shared between the positions
        # it accepts instead of counting as a whole extra starter for each.
        slot_counts: Dict[str, float] = {}
        for slot in self.starting_slots:
            eligible = SLOT_ELIGIBILITY.get(slot.upper(), ())
            if not eligible:
                continue
            share = 1.0 / len(eligible)
            for position in eligible:
                slot_counts[position] = slot_counts.get(position, 0.0) + share
        levels: Dict[str, float] = {}
        for position in self.league_positions():
            pool = sorted(
                (
                    self.points(pid)
                    for pid in self.projection_points
                    if position in self.player_positions(pid)
                ),
                reverse=True,
            )
            if not pool:
                continue
            starters = int(round(num_teams * slot_counts.get(position, 1.0)))
            index = min(len(pool) - 1, max(0, starters - 1))
            levels[position] = pool[index]
        return levels

    def trending_counts(self) -> Dict[str, int]:
        counts: Dict[str, int] = {}
        for entry in self.trending:
            if isinstance(entry, dict) and entry.get("player_id") is not None:
                count = entry.get("count")
                if isinstance(count, (int, float)):
                    counts[str(entry["player_id"])] = int(count)
        return counts

    def analyze_waivers(self, roster: dict) -> dict:
        positions = set(self.league_positions())
        replacement = self.replacement_levels()
        trending = self.trending_counts()
        usable = self.roster_active_players(roster)
        fixed = self.locked_starters(roster)
        baseline, baseline_lineup = self.optimize_with_fixed(usable, fixed)

        settings = self.league.get("settings") or {}
        waiver_type_raw = settings.get("waiver_type")
        budget = settings.get("waiver_budget")
        roster_settings = roster.get("settings") or {}
        used = roster_settings.get("waiver_budget_used")
        remaining = None
        if isinstance(budget, (int, float)):
            remaining = float(budget) - float(used or 0)
        # Only waiver_type decides FAAB: Sleeper fills in waiver_budget
        # (usually 100) on rolling and reverse-standings leagues too.
        if waiver_type_raw == 2:
            waiver_type = "FAAB"
        elif waiver_type_raw in (0, 1):
            waiver_type = "waiver priority"
        else:
            waiver_type = "unknown"
            self.warn("League waiver type could not be determined from league settings.")

        window = self.has_window
        n = self.n_weeks
        baseline_window, baseline_weeks = self.window_value(usable, fixed, use_locks=True)

        # Candidates: unrostered players projected in any window week, so a
        # player on bye (or out) this week can still be found as a stash.
        projected_any = set()
        for points in self.week_points:
            projected_any.update(points.keys())
        candidates_all = [
            pid
            for pid in projected_any
            if pid not in self.rostered and (set(self.player_positions(pid)) & positions)
        ]
        candidates_all.sort(key=lambda p: (-self.window_points(p), -self.points(p), str(p)))
        shortlist = candidates_all[: max(self.top_n * 6, 40)]

        starters_now = set(baseline_lineup.values())
        if window:
            # With future weeks the drop is chosen by what the roster loses
            # over the whole window, so a bye-week or briefly injured starter
            # is valued properly and needs no special protection.
            droppable = [
                pid
                for pid in sorted(usable, key=lambda p: (self.window_points(p), str(p)))
                if pid not in starters_now
            ][:10]
        else:
            # This week only: a bench player with no projection (bye) or who
            # is unavailable this week would look like the cheapest cut, so
            # only healthy, projected bench players qualify.
            droppable = [
                pid
                for pid in sorted(usable, key=lambda p: (self.points(p), str(p)))
                if pid not in starters_now
                and self.has_projection(pid)
                and self.availability(pid)[0]
            ][:10]
            protected = [
                pid for pid in usable
                if pid not in starters_now
                and (not self.has_projection(pid) or not self.availability(pid)[0])
            ]
            if protected:
                self.warn(
                    "Not suggested as drops (no projection or unavailable this week, "
                    "e.g. bye or injury): %s."
                    % ", ".join(sorted(self.player_name(p) for p in protected))
                )

        def drop_key(drop: str) -> Tuple[float, str]:
            return (self.window_points(drop) if window else self.points(drop), str(drop))

        rows = []
        for pid in shortlist:
            startable, notes = self.availability(pid)
            info = self.player(pid)
            if self.is_locked(pid):
                notes = notes + ["game already started this week"]
            with_window, with_weeks = self.window_value(list(usable) + [pid], fixed, use_locks=True)
            # A player whose game this week has already kicked off cannot help
            # until next week, which is also the week a waiver claim made now
            # pays off. Judge him on the next window week instead of a
            # guaranteed zero for this one.
            eval_w = 1 if (window and self.is_locked(pid)) else 0
            if eval_w == 0:
                _, with_lineup = self.optimize_with_fixed(list(usable) + [pid], fixed)
            else:
                _, with_lineup = self.optimize(list(usable) + [pid], w=eval_w)
                notes = notes + ["judged on week %d" % self.window_weeks[eval_w]]
            lineup_gain = with_weeks[eval_w] - baseline_weeks[eval_w]
            can_help = startable or (window and with_window > baseline_window)
            best_drop = None
            best_total = None
            best_weeks: List[float] = []
            if can_help:
                for drop in droppable:
                    if drop == pid:
                        continue
                    total, weeks = self.window_value(
                        [p for p in usable if p != drop] + [pid], fixed, use_locks=True
                    )
                    if (
                        best_drop is None
                        or total > best_total + 1e-9
                        or (abs(total - best_total) <= 1e-9 and drop_key(drop) < drop_key(best_drop))
                    ):
                        best_drop, best_total, best_weeks = drop, total, weeks
            if can_help and best_drop is None:
                notes = notes + ["no safe drop candidate on bench; needs an open roster spot"]
            if best_drop is not None:
                net_gain = best_weeks[eval_w] - baseline_weeks[eval_w]
                window_gain = best_total - baseline_window
            else:
                net_gain = lineup_gain
                window_gain = with_window - baseline_window
            position = self.primary_position(pid)
            rows.append(
                {
                    "player_id": pid,
                    "name": self.player_name(pid),
                    "position": position,
                    "team": info.get("team"),
                    "projection": r2(self.points(pid)) if self.has_projection(pid) else None,
                    "window_projection": r2(self.window_points(pid)) if window else None,
                    "replacement_level": r2(replacement.get(position)) if position in replacement else None,
                    "replacement_advantage": r2(self.points(pid) - replacement[position])
                    if position in replacement
                    else None,
                    "lineup_gain": r2(lineup_gain),
                    "net_gain": r2(net_gain),
                    "window_gain": r2(window_gain) if window else None,
                    "would_start_this_week": pid in set(with_lineup.values()),
                    "evaluated_week": self.window_weeks[eval_w] if self.window_weeks else None,
                    "drop_candidate": self.player_ref(best_drop) if best_drop else None,
                    "depth_chart_position": info.get("depth_chart_position"),
                    "depth_chart_order": info.get("depth_chart_order"),
                    "trending_adds_24h": trending.get(pid),
                    "available": startable,
                    "notes": notes,
                    "rest_of_season_value": r2(window_gain) if window else None,
                }
            )

        def window_or_net(row: dict) -> float:
            value = row["window_gain"] if window else row["net_gain"]
            return value or 0.0

        components = {"roster_improvement": True}
        components["opportunity"] = any(r["depth_chart_order"] is not None for r in rows)
        components["add_trend"] = bool(trending) and any(r["trending_adds_24h"] is not None for r in rows)
        components["rest_of_season_value"] = window
        components["schedule_fit"] = False
        omitted = sorted(k for k, v in components.items() if not v)
        active_weights = {k: WAIVER_WEIGHTS[k] for k, v in components.items() if v}
        total_weight = sum(active_weights.values()) or 1.0
        weights_used = {k: round(v / total_weight, 4) for k, v in active_weights.items()}
        if omitted:
            self.warn(
                "Waiver score components omitted (no reliable data): %s. "
                "Remaining weights renormalised." % ", ".join(omitted)
            )

        max_net = max([r["net_gain"] or 0.0 for r in rows], default=0.0)
        max_window = max([r["window_gain"] or 0.0 for r in rows], default=0.0)
        max_trend = max([r["trending_adds_24h"] or 0 for r in rows], default=0)

        def avoid_row(row: dict) -> bool:
            if window:
                return (row["window_gain"] or 0.0) <= 0 and not (
                    row["available"] and self.has_projection(row["player_id"])
                )
            return not row["available"] or not self.has_projection(row["player_id"])

        for row in rows:
            score = 0.0
            if "roster_improvement" in weights_used:
                value = (row["net_gain"] or 0.0) / max_net if max_net > 0 else 0.0
                score += weights_used["roster_improvement"] * max(0.0, min(1.0, value))
            if "rest_of_season_value" in weights_used:
                value = (row["window_gain"] or 0.0) / max_window if max_window > 0 else 0.0
                score += weights_used["rest_of_season_value"] * max(0.0, min(1.0, value))
            if "opportunity" in weights_used:
                order = row["depth_chart_order"]
                if isinstance(order, (int, float)):
                    opportunity = {1: 1.0, 2: 0.6, 3: 0.3}.get(int(order), 0.1)
                else:
                    opportunity = 0.0
                score += weights_used["opportunity"] * opportunity
            if "add_trend" in weights_used:
                trend = row["trending_adds_24h"] or 0
                score += weights_used["add_trend"] * ((trend / max_trend) if max_trend else 0.0)
            row["score"] = round(score, 4)
            # Bids and priority use the per-week average gain over the window.
            per_week_gain = window_or_net(row) / (n if window else 1)
            claimable = not avoid_row(row)
            if waiver_type == "FAAB" and remaining is not None and claimable:
                fraction = max(0.0, min(0.35, per_week_gain / 20.0))
                bid = int(round(remaining * fraction))
                if per_week_gain > 0:
                    bid = max(1, bid)
                row["suggested_bid"] = bid
                row["suggested_bid_pct"] = int(round(100 * bid / remaining)) if remaining > 0 else None
                row["bid_basis"] = (
                    "estimate from average projected gain over %d weeks and remaining budget" % n
                    if window else "estimate from net projected gain and remaining budget"
                )
            else:
                row["suggested_bid"] = None
                row["suggested_bid_pct"] = None
                row["bid_basis"] = None
            if waiver_type == "waiver priority":
                row["use_priority"] = bool(claimable and per_week_gain >= 1.0)
            else:
                row["use_priority"] = None

        def sort_key(row: dict):
            return (-(row.get("score") or 0.0), -window_or_net(row), row["name"])

        avoid = sorted([r for r in rows if avoid_row(r)], key=sort_key)[: self.top_n]
        available_rows = [r for r in rows if not avoid_row(r)]
        priority = sorted(
            [
                r for r in available_rows
                if r["would_start_this_week"] and (r["net_gain"] or 0) >= 1.0
                and (not window or (r["window_gain"] or 0) > 0)
            ],
            key=sort_key,
        )[: self.top_n]
        priority_ids = {r["player_id"] for r in priority}
        streamer_positions = {"QB", "TE", "K", "DEF"}
        streamers = sorted(
            [
                r
                for r in available_rows
                if r["player_id"] not in priority_ids
                and r["position"] in streamer_positions
                and (r["net_gain"] or 0) > 0
            ],
            key=sort_key,
        )[: self.top_n]
        streamer_ids = {r["player_id"] for r in streamers}
        bench_upgrades = sorted(
            [
                r
                for r in available_rows
                if r["player_id"] not in priority_ids
                and r["player_id"] not in streamer_ids
                and ((r["window_gain"] or 0) >= 1.0 if window else (r["net_gain"] or 0) > 0)
            ],
            key=sort_key,
        )[: self.top_n]

        return {
            "waiver": {
                "type": waiver_type,
                "budget": budget if waiver_type == "FAAB" and isinstance(budget, (int, float)) else None,
                "remaining": remaining if waiver_type == "FAAB" else None,
                "note": "Bid suggestions are estimates, not market data.",
            },
            "window_weeks": self.window_weeks,
            "weights_used": weights_used,
            "omitted_components": omitted,
            "candidates_considered": len(rows),
            "groups": {
                "priority": priority,
                "bench_upgrades": bench_upgrades,
                "streamers": streamers,
                "avoid": avoid,
            },
        }

    # -- trades -----------------------------------------------------------
    def slot_position(self, slot: str, pid: str) -> str:
        """The position a player fills in a slot. Two-way players (e.g. a
        WR/DB in a FLEX) count at the position that made them eligible, not
        their listed primary position."""
        allowed = SLOT_ELIGIBILITY.get(slot.upper(), ())
        primary = self.primary_position(pid)
        if primary and primary in allowed:
            return primary
        for position in self.player_positions(pid):
            if position in allowed:
                return position
        return primary or slot.upper()

    def positional_starter_points(self, assignment: Dict[int, str]) -> Dict[str, float]:
        result: Dict[str, float] = {}
        for index, pid in assignment.items():
            slot = self.starting_slots[index]
            position = self.slot_position(slot, pid)
            result[position] = round(result.get(position, 0.0) + self.points(pid), 2)
        return result

    def average_depth(self, players: Sequence[str]) -> Dict[str, float]:
        """Optimal starting points by position, averaged over the window so a
        one-week bye doesn't show up as a positional need."""
        totals: Dict[str, float] = {}
        for w in range(self.n_weeks):
            _, assignment = self.optimize(players, w=w)
            for index, pid in assignment.items():
                position = self.slot_position(self.starting_slots[index], pid)
                totals[position] = totals.get(position, 0.0) + self.points(pid, w)
        return {k: round(v / self.n_weeks, 2) for k, v in totals.items()}

    def roster_profile(self, roster: dict) -> dict:
        usable = self.roster_active_players(roster)
        total, weeks = self.window_value(usable)
        starters = set()
        for w in range(self.n_weeks):
            starters.update(self.optimize(usable, w=w)[1].values())
        replacement = self.replacement_levels()
        bench_above_replacement = 0.0
        entries = []
        for pid in usable:
            position = self.primary_position(pid)
            level = replacement.get(position)
            above = self.points(pid) - level if level is not None else None
            if pid not in starters and above is not None and above > 0:
                bench_above_replacement += above
            if not any(self.startable_in(pid, w) for w in range(self.n_weeks)):
                continue
            without, _ = self.window_value([p for p in usable if p != pid])
            cost = total - without
            entries.append(
                {
                    "player_id": pid,
                    "name": self.player_name(pid),
                    "position": position,
                    "projection": r2(self.points(pid)),
                    "window_projection": r2(self.window_points(pid)),
                    "lineup_cost": r2(cost),
                    "above_replacement": r2(above),
                }
            )
        entries.sort(key=lambda s: (-(s["window_projection"] or 0.0), s["name"]))
        # Surplus: a player the roster can lose without weakening its optimal
        # lineups by more than half a projected point per window week.
        surplus = [e for e in entries if (e["lineup_cost"] or 0.0) <= 0.5 * self.n_weeks]
        return {
            "roster_id": roster.get("roster_id"),
            "team": self.team_name(roster.get("roster_id")),
            "optimal_points": total,
            "weeks": weeks,
            "starters": starters,
            "usable": usable,
            "depth": self.average_depth(usable),
            "bench_above_replacement": r2(bench_above_replacement),
            "surplus": surplus,
            "entries": entries,
        }

    def analyze_trades(self, my_roster: dict) -> dict:
        profiles = {}
        for roster in self.rosters:
            profiles[roster.get("roster_id")] = self.roster_profile(roster)
        mine = profiles[self.my_roster_id]

        positions = sorted({p for profile in profiles.values() for p in profile["depth"]})
        league_average = {}
        for position in positions:
            values = [profile["depth"].get(position, 0.0) for profile in profiles.values()]
            league_average[position] = round(sum(values) / len(values), 2) if values else 0.0

        def needs_of(profile: dict) -> List[dict]:
            result = []
            for position in positions:
                mine_points = profile["depth"].get(position, 0.0)
                average = league_average[position]
                if average > 0 and mine_points < average * 0.9:
                    result.append(
                        {
                            "position": position,
                            "starter_points": r2(mine_points),
                            "league_average": r2(average),
                            "shortfall": r2(average - mine_points),
                        }
                    )
            result.sort(key=lambda n: -(n["shortfall"] or 0.0))
            return result

        my_needs = needs_of(mine)
        my_base = mine["optimal_points"] or 0.0
        my_base_weeks = mine["weeks"]
        n = self.n_weeks
        partners = []
        for roster in self.rosters:
            rid = roster.get("roster_id")
            if rid == self.my_roster_id:
                continue
            theirs = profiles[rid]
            their_base = theirs["optimal_points"] or 0.0
            packages = []

            def pool(profile: dict, surplus_limit: int, extra_limit: int) -> List[dict]:
                chosen = list(profile["surplus"][:surplus_limit])
                seen = {entry["player_id"] for entry in chosen}
                for entry in profile["entries"]:
                    if len(chosen) >= surplus_limit + extra_limit:
                        break
                    if entry["player_id"] in seen:
                        continue
                    chosen.append(entry)
                    seen.add(entry["player_id"])
                return chosen

            my_options = pool(mine, 5, 3)
            their_options = pool(theirs, 5, 3)

            def exchange_value(side: List[dict]) -> float:
                return sum(self.window_points(entry["player_id"]) for entry in side)

            def evaluate(give: List[dict], get: List[dict]) -> Optional[dict]:
                give_ids = {g["player_id"] for g in give}
                get_ids = {g["player_id"] for g in get}
                my_players = [p for p in mine["usable"] if p not in give_ids] + sorted(get_ids)
                their_players = [p for p in theirs["usable"] if p not in get_ids] + sorted(give_ids)
                my_after, my_weeks = self.window_value(my_players)
                their_after, their_weeks = self.window_value(their_players)
                my_gain = my_after - my_base
                their_gain = their_after - their_base
                # Both sides must gain something real; a 0.01-point "gain"
                # rounds to 0 in the report and is no reason to trade.
                if my_gain < MIN_TRADE_GAIN * n or their_gain < MIN_TRADE_GAIN * n:
                    return None
                value_out = exchange_value(give)
                value_in = exchange_value(get)
                gap = abs(value_out - value_in)
                largest = max(value_out, value_in)
                # Fair when the exchanged weekly projection is within the
                # tolerance of the larger side, or within one projected point.
                if gap > max(1.0 * n, self.fairness * largest):
                    return None
                if (give_ids & mine["starters"]) and my_gain < 1.0 * n:
                    return None  # protect core starters unless the return is material
                return {
                    "give": [
                        {"player_id": g["player_id"], "name": g["name"], "position": g["position"],
                         "projection": g["projection"], "window_projection": g["window_projection"]}
                        for g in give
                    ],
                    "get": [
                        {"player_id": g["player_id"], "name": g["name"], "position": g["position"],
                         "projection": g["projection"], "window_projection": g["window_projection"]}
                        for g in get
                    ],
                    "window_weeks": n,
                    "my_gain": r2(my_gain),
                    "their_gain": r2(their_gain),
                    "my_gain_this_week": r2(my_weeks[0] - my_base_weeks[0]),
                    "their_gain_this_week": r2(their_weeks[0] - theirs["weeks"][0]),
                    "value_given": r2(value_out),
                    "value_received": r2(value_in),
                    "fairness_gap": r2(gap),
                    "my_depth_after": self.average_depth(my_players),
                }

            for give in my_options:
                for get in their_options:
                    package = evaluate([give], [get])
                    if package:
                        packages.append(package)
            for give_pair in combinations(my_options[:4], 2):
                for get in their_options[:3]:
                    package = evaluate(list(give_pair), [get])
                    if package:
                        packages.append(package)
            packages.sort(key=lambda p: (-(p["my_gain"] or 0.0), p["fairness_gap"] or 0.0))
            partners.append(
                {
                    "roster_id": rid,
                    "team": theirs["team"],
                    "needs": needs_of(theirs),
                    "surplus": theirs["surplus"][:5],
                    "depth_before": {k: r2(v) for k, v in theirs["depth"].items()},
                    "packages": packages[: max(1, min(3, self.top_n))],
                }
            )
        partners.sort(key=lambda p: -(p["packages"][0]["my_gain"] if p["packages"] else 0.0))
        return {
            "method": (
                "Optimal-starter points by position, bench value above replacement, "
                "and re-optimised lineups for both teams after each swap."
            ),
            "my_depth": {k: r2(v) for k, v in mine["depth"].items()},
            "league_average_depth": league_average,
            "my_needs": my_needs,
            "my_surplus": mine["surplus"][:5],
            "my_bench_above_replacement": mine["bench_above_replacement"],
            "fairness_tolerance": self.fairness,
            "window_weeks": self.window_weeks,
            "partners": [p for p in partners if p["packages"]],
        }

    # -- report -----------------------------------------------------------
    # -- custom trade analyzer -------------------------------------------
    # Grades on projected starting points gained per window week. The scale
    # is deliberately absolute: one point a week is a real but small edge for
    # a typical 120-150 point lineup.
    GRADE_SCALE = (
        (4.0, "A+"), (3.0, "A"), (2.25, "A-"), (1.5, "B+"), (1.0, "B"), (0.5, "B-"),
        (0.25, "C+"), (-0.25, "C"), (-0.5, "C-"), (-1.0, "D+"), (-1.5, "D"),
    )
    NAME_SUFFIXES = {"jr", "sr", "ii", "iii", "iv", "v"}

    def window_label(self) -> str:
        weeks = self.window_weeks
        if self.config.get("horizon_mode") == "ros" and len(weeks) > 1:
            last = self.config.get("last_week")
            if isinstance(last, int) and weeks[-1] < last:
                return "rest of season, weeks %d-%d (no projections after week %d yet)" % (weeks[0], weeks[-1], weeks[-1])
            return "rest of season (weeks %d-%d)" % (weeks[0], weeks[-1])
        if len(weeks) == 1:
            return "week %d only" % weeks[0]
        return "weeks " + ", ".join(str(w) for w in weeks)

    def two_grades(self, a_this: float, b_this: float, a_pw: float, b_pw: float) -> dict:
        """Immediate impact (this week) and value over the window, graded
        separately on the same per-week scale."""
        return {
            "this_week": {"week": self.window_weeks[0] if self.window_weeks else None,
                          "my_grade": self.grade_for(a_this), "their_grade": self.grade_for(b_this),
                          "my_gain": r2(a_this), "their_gain": r2(b_this)},
            "window": {"weeks": self.window_weeks, "label": self.window_label(),
                       "rest_of_season": self.config.get("horizon_mode") == "ros",
                       "my_grade": self.grade_for(a_pw), "their_grade": self.grade_for(b_pw),
                       "my_gain_per_week": r2(a_pw), "their_gain_per_week": r2(b_pw)},
        }

    def trade_deadline_flag(self) -> Optional[str]:
        deadline = (self.league.get("settings") or {}).get("trade_deadline")
        week = int(self.config.get("week") or 0)
        if isinstance(deadline, int) and not isinstance(deadline, bool) and 0 < deadline < 99 and week > deadline:
            return "The league's trade deadline (week %d) has passed." % deadline
        return None

    @classmethod
    def grade_for(cls, per_week: float) -> str:
        for floor, letter in cls.GRADE_SCALE:
            if per_week >= floor - 1e-9:
                return letter
        return "F"

    @staticmethod
    def acceptance_for(their_per_week: float) -> str:
        if their_per_week >= 0.5:
            return "likely"
        if their_per_week >= -0.5:
            return "possible"
        return "unlikely"

    @staticmethod
    def neutral_verdict(a_pw: float, b_pw: float, a: str, b: str) -> str:
        """Verdict for a trade you are judging for someone else."""
        if a_pw >= 0.5 and b_pw >= 0.5:
            return "Win-win: both %s and %s improve." % (a, b)
        if abs(a_pw) < 0.5 and abs(b_pw) < 0.5:
            return "About even: neither side gains or loses much."
        if a_pw >= b_pw:
            winner, loser, margin = a, b, a_pw - b_pw
        else:
            winner, loser, margin = b, a, b_pw - a_pw
        if margin >= 3.0:
            return "Lopsided: %s wins this clearly; %s should ask for more." % (winner, loser)
        if margin >= 1.0:
            return "%s wins this one; %s gives up more than they get." % (winner, loser)
        return "Slight edge to %s; close to fair." % winner

    @classmethod
    def normalise_name(cls, text: str) -> List[str]:
        cleaned = "".join(ch if ch.isalnum() or ch.isspace() else "" for ch in lower(text).replace("-", " "))
        return [t for t in cleaned.split() if t and t not in cls.NAME_SUFFIXES]

    @staticmethod
    def parse_trade_text(text: str) -> List[Tuple[str, List[str], List[str]]]:
        """'A, B for C; D for E' -> [(raw, [A, B], [C]), (raw, [D], [E])].
        ' for ', '->' and '=>' separate the sides; ';' separates trades."""
        trades = []
        for raw in str(text or "").split(";"):
            raw = raw.strip()
            if not raw:
                continue
            sides = None
            for sep in (" for ", "->", "=>"):
                low = raw.lower()
                idx = low.find(sep)
                if idx >= 0:
                    sides = (raw[:idx], raw[idx + len(sep):])
                    break
            if sides is None:
                trades.append((raw, [], []))
                continue
            give = [p.strip() for p in sides[0].split(",") if p.strip()]
            get = [p.strip() for p in sides[1].split(",") if p.strip()]
            trades.append((raw, give, get))
        return trades

    def resolve_player(self, token: str, pool: Sequence[str], with_meta: bool = False) -> Tuple[Optional[str], Optional[str]]:
        """Match a name or player id against `pool`. Returns (pid, error).
        With `with_meta`, a position or NFL team in the text narrows the
        match ("Josh Allen BUF") and candidates are listed with both."""
        token = token.strip()
        if token.lower().startswith("id:"):
            token = token[3:].strip()
        if token in pool:
            return token, None
        wanted = self.normalise_name(token)
        if not wanted:
            return None, "empty player name"
        exact = [p for p in pool if self.normalise_name(self.player_name(p)) == wanted]
        if len(exact) == 1:
            return exact[0], None
        def tokens(p: str) -> set:
            found = set(self.normalise_name(self.player_name(p)))
            if with_meta:
                found.update(t for t in (lower(self.primary_position(p)), lower(self.player(p).get("team"))) if t)
            return found

        partial = [p for p in pool if set(wanted) <= tokens(p)]
        if len(partial) == 1:
            return partial[0], None
        candidates = exact or partial
        if candidates:
            def label(p: str) -> str:
                if not with_meta:
                    return self.player_name(p)
                return "%s (%s, %s)" % (self.player_name(p), self.primary_position(p) or "?",
                                        self.player(p).get("team") or "FA")
            listed = sorted(label(p) for p in candidates)
            more = "" if len(listed) <= 8 else " and %d more" % (len(listed) - 8)
            hint = ""
            if with_meta:
                first = candidates[0]
                positions = {self.primary_position(p) for p in candidates}
                extra = (self.primary_position(first) if len(positions) > 1
                         else self.player(first).get("team") or self.primary_position(first) or "")
                hint = "; add a position or team, e.g. '%s %s'" % (token, extra)
            return None, "'%s' is ambiguous: %s%s%s" % (token, ", ".join(listed[:8]), more, hint)
        return None, "'%s' not found" % token

    def roster_limit(self) -> int:
        """Roster spots for active players (starters + bench; IR/taxi excluded)."""
        return len([p for p in self.roster_positions if p.upper() not in ("IR", "TAXI", "RESERVE")])

    def trim_roster(self, players: List[str], keep: set, limit_floor: int) -> Tuple[List[str], List[str]]:
        """Drop the cheapest players (by window value) until the roster fits.
        `keep` (just-acquired players) are dropped only as a last resort."""
        players = list(players)
        limit = max(self.roster_limit(), limit_floor)
        drops: List[str] = []
        while len(players) > limit:
            best = None
            for pid in players:
                total, _ = self.window_value([p for p in players if p != pid])
                key = (pid in keep, -total, self.player_name(pid))
                if best is None or key < best[0]:
                    best = (key, pid)
            players.remove(best[1])
            drops.append(best[1])
        return players, drops

    def weeks_started(self, players: Sequence[str], targets: Iterable[str]) -> Dict[str, int]:
        counts = {str(t): 0 for t in targets}
        for w in range(self.n_weeks):
            for pid in self.optimize(players, w=w)[1].values():
                if pid in counts:
                    counts[pid] += 1
        return counts

    def trade_flags(self, pid: str, side: str) -> List[str]:
        flags = []
        info = self.player(pid)
        name = self.player_name(pid)
        injury = info.get("injury_status")
        status = lower(info.get("status"))
        if status in LONG_TERM_UNAVAILABLE:
            flags.append("%s %s is %s" % (side, name, info.get("status")))
        elif injury:
            flags.append("%s %s is %s" % (side, name, injury))
        missing = [str(self.window_weeks[w]) for w in range(self.n_weeks) if not self.has_projection(pid, w)]
        if missing:
            flags.append("%s %s has no projection in week %s (bye or out)" % (side, name, ", ".join(missing)))
        if self.is_locked(pid):
            flags.append("%s %s has already played this week" % (side, name))
        return flags

    def analyze_custom_trades(self) -> Optional[List[dict]]:
        text = self.config.get("custom_trades")
        if not text:
            return None
        rosters = {r.get("roster_id"): r for r in self.rosters}
        active = {rid: self.roster_active_players(r) for rid, r in rosters.items()}
        owner = {p: rid for rid, players in active.items() for p in players}
        my_players = active.get(self.my_roster_id, [])
        everyone = sorted(owner)
        results = []
        for raw, give_tokens, get_tokens in self.parse_trade_text(text):
            result: dict = {"input": raw}
            results.append(result)
            if not give_tokens or not get_tokens:
                result["error"] = "Write a trade as 'players you give for players you get', e.g. 'Josh Allen for Kenneth Walker III'."
                continue
            errors = []
            give, get = [], []
            # The giving side is usually you: look on your roster first, then
            # anywhere in the league (a trade between two other teams).
            for token in give_tokens:
                pid, err = self.resolve_player(token, my_players)
                if err and "not found" in err:
                    pid, err = self.resolve_player(token, everyone)
                if err:
                    errors.append("give: %s on any roster in this league (use --value-trade for players elsewhere)" % err
                                  if "not found" in err else "give: " + err)
                elif pid in give:
                    errors.append("give: %s listed twice" % self.player_name(pid))
                else:
                    give.append(pid)
            a_teams = {owner[p] for p in give}
            if not errors and len(a_teams) > 1:
                errors.append("players to give are on different teams (%s); only two-team trades are supported"
                              % ", ".join(sorted(str(self.team_name(r)) for r in a_teams)))
            a_id = next(iter(a_teams)) if len(a_teams) == 1 else self.my_roster_id
            get_pool = [p for p in everyone if owner[p] != a_id]
            for token in get_tokens:
                pid, err = self.resolve_player(token, get_pool)
                if err:
                    where = "on another roster" if a_id == self.my_roster_id else "on a roster other than the giving team's"
                    errors.append("get: %s %s" % (err, where) if "not found" in err else "get: " + err)
                elif pid in get:
                    errors.append("get: %s listed twice" % self.player_name(pid))
                else:
                    get.append(pid)
            partners = {owner[p] for p in get}
            if not errors and len(partners) > 1:
                errors.append("players to get are on different teams (%s); only two-team trades are supported"
                              % ", ".join(sorted(str(self.team_name(r)) for r in partners)))
            if errors:
                result["error"] = "; ".join(errors)
                continue
            partner_id = partners.pop()
            is_me = a_id == self.my_roster_id
            a_players = active[a_id]
            theirs = active[partner_id]
            a_name = self.team_name(a_id) or "roster %s" % a_id
            b_name = self.team_name(partner_id) or "roster %s" % partner_id
            result["side_a"] = {"roster_id": a_id, "team": self.team_name(a_id), "is_me": is_me}
            result["partner"] = {"roster_id": partner_id, "team": self.team_name(partner_id)}
            n = self.n_weeks

            my_base, my_base_weeks = self.window_value(a_players)
            their_base, their_base_weeks = self.window_value(theirs)
            my_after_players = [p for p in a_players if p not in give] + get
            their_after_players = [p for p in theirs if p not in get] + give
            my_after_players, my_drops = self.trim_roster(my_after_players, set(get), len(a_players))
            their_after_players, their_drops = self.trim_roster(their_after_players, set(give), len(theirs))
            my_after, my_weeks = self.window_value(my_after_players)
            their_after, their_weeks = self.window_value(their_after_players)
            my_gain = my_after - my_base
            their_gain = their_after - their_base
            my_pw = my_gain / n
            their_pw = their_gain / n

            started_before_mine = self.weeks_started(a_players, give)
            started_after_mine = self.weeks_started(my_after_players, get)
            started_before_theirs = self.weeks_started(theirs, get)
            started_after_theirs = self.weeks_started(their_after_players, give)

            def side(pids: List[str], before: Dict[str, int], after: Dict[str, int]) -> List[dict]:
                rows = []
                for pid in pids:
                    ref = self.player_ref(pid)
                    ref["window_projection"] = r2(self.window_points(pid))
                    ref["weeks_started_before"] = before.get(pid)
                    ref["weeks_started_after"] = after.get(pid)
                    rows.append(ref)
                return rows

            result["give"] = side(give, started_before_mine, started_after_theirs)
            result["get"] = side(get, started_before_theirs, started_after_mine)
            value_given = sum(self.window_points(p) for p in give)
            value_received = sum(self.window_points(p) for p in get)

            my_grade = self.grade_for(my_pw)
            their_grade = self.grade_for(their_pw)
            acceptance = self.acceptance_for(their_pw)
            if not is_me:
                verdict = self.neutral_verdict(my_pw, their_pw, a_name, b_name)
            elif my_pw >= 0.5:
                if their_pw >= 0:
                    verdict = "Good for you and it helps them too: worth proposing."
                elif their_pw >= -1.0:
                    verdict = "Good for you; slightly worse for them, so they may need convincing."
                else:
                    verdict = "Lopsided in your favour; unlikely to be accepted as is."
            elif my_pw >= -0.25:
                verdict = ("Roughly neutral for you" + (", but it helps them." if their_pw >= 0.5 else "."))
            else:
                verdict = "Costs you projected points: not recommended" + (
                    " (they win this one)." if their_pw >= 0.5 else ".")

            you = "you" if is_me else a_name
            them = "they" if is_me else b_name
            your = "your" if is_me else a_name + "'s"
            notes = []
            if len(give) > len(get) and value_given > value_received and my_gain > 0:
                notes.append("Consolidation: %s give%s more total points but %s starting lineup improves."
                             % (you, "" if is_me else "s", your))
            if len(get) > len(give) and their_gain > 0 and value_received > value_given:
                notes.append("%s consolidate%s: %s get%s more total points, %s upgrade%s a starter."
                             % ("They" if is_me else b_name, "" if is_me else "s", you, "" if is_me else "s",
                                them, "" if is_me else "s"))
            if my_drops:
                notes.append("To make room %s would drop: %s." % (you, ", ".join(self.player_name(p) for p in my_drops)))
            if their_drops:
                notes.append("To make room %s would drop: %s." % ("they" if is_me else b_name,
                                                                   ", ".join(self.player_name(p) for p in their_drops)))
            if len(give) > len(get):
                notes.append("Opens %d roster spot(s) for a waiver pickup (not included in the grade)."
                             % (len(give) - len(get)))
            for pid in get:
                if started_after_mine.get(pid, 0) == 0:
                    notes.append("%s would not start for %s in any window week."
                                 % (self.player_name(pid), "you" if is_me else a_name))
            if n == 1:
                notes.append("Judged on this week only (--horizon 0); rest-of-season value is not included.")

            flags = []
            for pid in get:
                flags.extend(self.trade_flags(pid, "You get" if is_me else a_name + " gets"))
            for pid in give:
                flags.extend(self.trade_flags(pid, "You give" if is_me else a_name + " gives"))
            deadline = self.trade_deadline_flag()
            if deadline:
                flags.append(deadline)
            my_this = my_weeks[0] - my_base_weeks[0] if my_weeks and my_base_weeks else 0.0
            their_this = their_weeks[0] - their_base_weeks[0] if their_weeks and their_base_weeks else 0.0
            if n > 1 and self.grade_for(my_this) != my_grade:
                notes.append("This week and the longer view disagree for %s: %+.1f points this week (%s), "
                             "%+.1f a week over %s (%s)."
                             % (you, my_this, self.grade_for(my_this), my_pw, self.window_label(), my_grade))

            result.update({
                "window_weeks": self.window_weeks,
                "my_gain": r2(my_gain),
                "their_gain": r2(their_gain),
                "my_gain_per_week": r2(my_pw),
                "their_gain_per_week": r2(their_pw),
                "my_weekly_gains": [r2(a - b) for a, b in zip(my_weeks, my_base_weeks)],
                "their_weekly_gains": [r2(a - b) for a, b in zip(their_weeks, their_base_weeks)],
                "value_given": r2(value_given),
                "value_received": r2(value_received),
                "my_grade": my_grade,
                "their_grade": their_grade,
                "grades": self.two_grades(my_this, their_this, my_pw, their_pw),
                "acceptance": acceptance,
                "verdict": verdict,
                "my_drops": [self.player_ref(p) for p in my_drops],
                "their_drops": [self.player_ref(p) for p in their_drops],
                "notes": notes,
                "flags": flags,
            })
        return results

    # -- open trade grader (any players, no rosters) ----------------------
    OPEN_POSITIONS = ("QB", "RB", "WR", "TE", "K", "DEF")
    # Starters per team in a generic lineup (1 QB, 2 RB, 2 WR, 1 TE, 1 FLEX
    # shared by RB/WR/TE, K, DEF); times the number of teams this gives the
    # replacement-level starter at each position.
    GENERIC_STARTERS = {"QB": 1.0, "RB": 2 + 1 / 3, "WR": 2 + 1 / 3, "TE": 1 + 1 / 3, "K": 1.0, "DEF": 1.0}
    SCORING_FIELDS = {"ppr": "pts_ppr", "half": "pts_half_ppr", "std": "pts_std"}
    SCORING_LABELS = {"ppr": "PPR", "half": "half-PPR", "std": "standard", "league": "your league's scoring"}

    def open_points(self, pid: str, w: int, scoring: str) -> Optional[float]:
        """Projected points for any player in window week `w` under a generic
        scoring format (or the loaded league's scoring)."""
        if scoring == "league":
            return self.points(pid, w) if self.has_projection(pid, w) else None
        stats = self.week_stats[w].get(str(pid)) if w < len(self.week_stats) else None
        if not isinstance(stats, dict):
            return None
        value = stats.get(self.SCORING_FIELDS[scoring])
        if isinstance(value, (int, float)):
            return float(value)
        rec = stats.get("rec") if isinstance(stats.get("rec"), (int, float)) else 0.0
        # Derive the format from whichever total the feed has.
        base = None
        for field, per_rec in (("pts_ppr", 1.0), ("pts_half_ppr", 0.5), ("pts_std", 0.0)):
            if isinstance(stats.get(field), (int, float)):
                base = float(stats[field]) - per_rec * rec
                break
        if base is None:
            return None
        return base + {"ppr": 1.0, "half": 0.5, "std": 0.0}[scoring] * rec

    def open_pool(self, scoring: str) -> List[str]:
        cache = self.__dict__.setdefault("_open_pool_cache", {})
        if scoring not in cache:
            ids = set()
            for stats in self.week_stats:
                ids.update(stats.keys())
            pool = []
            for pid in ids:
                if self.primary_position(pid) not in self.OPEN_POSITIONS:
                    continue
                total = sum(self.open_points(pid, w, scoring) or 0.0 for w in range(self.n_weeks))
                if total > 0:
                    pool.append(pid)
            cache[scoring] = sorted(pool)
        return cache[scoring]

    def open_replacement(self, scoring: str, teams: int) -> List[Dict[str, float]]:
        cache = self.__dict__.setdefault("_open_repl_cache", {})
        key = (scoring, teams)
        if key not in cache:
            levels = []
            pool = self.open_pool(scoring)
            for w in range(self.n_weeks):
                by_pos: Dict[str, List[float]] = {}
                for pid in pool:
                    value = self.open_points(pid, w, scoring)
                    if value is not None:
                        by_pos.setdefault(self.primary_position(pid), []).append(value)
                week = {}
                for pos, starters in self.GENERIC_STARTERS.items():
                    values = sorted(by_pos.get(pos, []), reverse=True)
                    index = max(0, int(round(teams * starters)) - 1)
                    week[pos] = values[index] if index < len(values) else 0.0
                levels.append(week)
            cache[key] = levels
        return cache[key]

    def open_value(self, pid: str, scoring: str, teams: int) -> Tuple[float, float, List[Optional[float]]]:
        """(points above replacement, raw points, weekly points) over the
        window. A week without a projection (bye, injury) is worth nothing:
        you would start a replacement-level player instead."""
        levels = self.open_replacement(scoring, teams)
        position = self.primary_position(pid)
        vor = raw = 0.0
        weekly: List[Optional[float]] = []
        for w in range(self.n_weeks):
            value = self.open_points(pid, w, scoring)
            weekly.append(r2(value) if value is not None else None)
            if value is None:
                continue
            raw += value
            vor += max(0.0, value - levels[w].get(position, 0.0))
        return vor, raw, weekly

    def analyze_value_trades(self) -> Optional[List[dict]]:
        text = self.config.get("value_trades")
        if not text:
            return None
        scoring = str(self.config.get("value_scoring") or "ppr").lower()
        if scoring not in self.SCORING_LABELS:
            scoring = "ppr"
        teams = int(self.config.get("value_teams") or 12)
        n = self.n_weeks
        pool = self.open_pool(scoring)
        everyone = sorted(
            pid for pid, info in self.players.items()
            if isinstance(info, dict) and self.primary_position(pid) in self.OPEN_POSITIONS
            and info.get("active") is not False
        )
        levels = self.open_replacement(scoring, teams)
        results = []
        for raw, a_tokens, b_tokens in self.parse_trade_text(text):
            result: dict = {"input": raw}
            results.append(result)
            if not a_tokens or not b_tokens:
                result["error"] = "Write a trade as 'players side A gives for players side B gives', e.g. 'Josh Allen for Kenneth Walker III'."
                continue
            errors = []
            sides: List[List[str]] = [[], []]
            for label, tokens, picked in (("side A", a_tokens, sides[0]), ("side B", b_tokens, sides[1])):
                for token in tokens:
                    # Projected players first, then anyone in the player database.
                    pid, err = self.resolve_player(token, pool, with_meta=True)
                    if err and "not found" in err:
                        pid, err = self.resolve_player(token, everyone, with_meta=True)
                    if err:
                        errors.append("%s: %s" % (label, err))
                    elif pid in sides[0] or pid in sides[1]:
                        errors.append("%s: %s is already in this trade" % (label, self.player_name(pid)))
                    else:
                        picked.append(pid)
            if errors:
                result["error"] = "; ".join(errors)
                continue
            give, get = sides

            def entry(pid: str) -> dict:
                vor, raw_pts, weekly = self.open_value(pid, scoring, teams)
                info = self.player(pid)
                return {
                    "player_id": pid, "name": self.player_name(pid), "position": self.primary_position(pid),
                    "team": info.get("team"), "injury_status": info.get("injury_status"),
                    "window_points": r2(raw_pts), "value_over_replacement": r2(vor), "weekly_points": weekly,
                }

            give_rows = [entry(p) for p in give]
            get_rows = [entry(p) for p in get]
            value_given = sum(r["value_over_replacement"] or 0.0 for r in give_rows)
            value_received = sum(r["value_over_replacement"] or 0.0 for r in get_rows)
            a_gain = value_received - value_given
            a_pw, b_pw = a_gain / n, -a_gain / n

            def this_week_vor(pid: str) -> float:
                value = self.open_points(pid, 0, scoring)
                return 0.0 if value is None else max(0.0, value - levels[0].get(self.primary_position(pid), 0.0))

            a_this = sum(this_week_vor(p) for p in get) - sum(this_week_vor(p) for p in give)

            notes = ["Values each player by projected points above a replacement-level starter in a "
                     "%d-team league (%s) over weeks %s; team needs, depth and roster spots are not known."
                     % (teams, self.SCORING_LABELS[scoring], ", ".join(str(w) for w in self.window_weeks))]
            rows_all = give_rows + get_rows
            best = max(rows_all, key=lambda r: (r["value_over_replacement"] or 0.0, r["name"]))
            best_to_b = best in give_rows
            fewer_side_gets_best = (len(give) < len(get)) if best_to_b else (len(get) < len(give))
            if fewer_side_gets_best and (best["value_over_replacement"] or 0) > 0:
                best_side = "Side B" if best_to_b else "Side A"
                notes.append("%s gets the best player in the deal (%s); with a thin bench or in a deep "
                             "league that is worth more than these totals show." % (best_side, best["name"]))
            more = len(get) - len(give)
            if more:
                notes.append("%s receives %d more player(s) and would need to drop someone."
                             % ("Side A" if more > 0 else "Side B", abs(more)))
            for r in rows_all:
                if (r["value_over_replacement"] or 0.0) <= 0.0:
                    notes.append("%s projects at or below replacement level, so adds no value here." % r["name"])
            if n == 1:
                notes.append("Judged on this week only (--horizon 0); rest-of-season value is not included.")

            flags = []
            for side_label, pids in (("Side A gets", get), ("Side B gets", give)):
                for pid in pids:
                    flags.extend(f for f in self.trade_flags(pid, side_label) if "already played" not in f)

            result.update({
                "mode": "open",
                "scoring": scoring,
                "teams": teams,
                "window_weeks": self.window_weeks,
                "give": give_rows,
                "get": get_rows,
                "value_given": r2(value_given),
                "value_received": r2(value_received),
                "points_given": r2(sum(r["window_points"] or 0.0 for r in give_rows)),
                "points_received": r2(sum(r["window_points"] or 0.0 for r in get_rows)),
                "my_gain": r2(a_gain),
                "their_gain": r2(-a_gain),
                "my_gain_per_week": r2(a_pw),
                "their_gain_per_week": r2(b_pw),
                "my_grade": self.grade_for(a_pw),
                "their_grade": self.grade_for(b_pw),
                "grades": self.two_grades(a_this, -a_this, a_pw, b_pw),
                "acceptance": self.acceptance_for(b_pw),
                "verdict": self.neutral_verdict(a_pw, b_pw, "Side A", "Side B"),
                "replacement_levels": {
                    pos: r2(sum(week[pos] for week in levels) / max(1, len(levels))) for pos in self.GENERIC_STARTERS
                },
                "notes": notes,
                "flags": flags,
            })
        return results

    # -- history: past weeks, projection accuracy, recent form -----------
    @staticmethod
    def _stat_records(feed) -> List[Tuple[str, dict]]:
        """A stats feed as (player_id, stats): a list of records like the
        projection feed, or an object keyed by player id."""
        out: List[Tuple[str, dict]] = []
        if isinstance(feed, list):
            for record in feed:
                if isinstance(record, dict) and record.get("player_id") is not None and isinstance(record.get("stats"), dict):
                    out.append((str(record["player_id"]), record["stats"]))
        elif isinstance(feed, dict):
            for pid, value in feed.items():
                if isinstance(value, dict):
                    stats = value.get("stats") if isinstance(value.get("stats"), dict) else value
                    out.append((str(pid), stats))
        return out

    def analyze_history(self) -> Optional[dict]:
        """Score past weeks with this league's rules, record this week's
        pre-kickoff projections, and measure projection accuracy.

        Sets self.history_updates (rows for the history database) and
        self.history_form (recent form per player)."""
        self.history_updates: Dict[str, list] = {"projections": [], "actuals": []}
        self.history_form: Dict[str, dict] = {}
        self.history_accuracy: Dict[str, dict] = {}
        self.history_player_misses: Dict[str, List[float]] = {}
        self.history_usage: Dict[Tuple[int, str], dict] = {}
        self.usage_sources: Dict[int, str] = {}
        hist = self.bundle.get("history")
        if not isinstance(hist, dict):
            return None
        week = int(self.config.get("week") or 0)
        stored = hist.get("stored") or {}
        proj: Dict[Tuple[int, str], float] = {}
        proj_src: Dict[Tuple[int, str], str] = {}
        act: Dict[Tuple[int, str], float] = {}
        act_src: Dict[Tuple[int, str], str] = {}
        usage: Dict[Tuple[int, str], dict] = {}
        for row in stored.get("projections") or []:
            w, pid, pts, src = int(row[0]), str(row[1]), row[2], row[3]
            if isinstance(pts, (int, float)):
                proj[(w, pid)], proj_src[(w, pid)] = float(pts), src
        for row in stored.get("actuals") or []:
            w, pid, pts, src = int(row[0]), str(row[1]), row[2], row[3]
            if isinstance(pts, (int, float)):
                act[(w, pid)], act_src[(w, pid)] = float(pts), src
            if len(row) > 4 and isinstance(row[4], dict) and row[4]:
                usage[(w, pid)] = row[4]

        for wk, entry in sorted((hist.get("raw") or {}).items(), key=lambda kv: int(kv[0])):
            w = int(wk)
            for record in entry.get("projections") or []:
                if not isinstance(record, dict) or record.get("player_id") is None or not isinstance(record.get("stats"), dict):
                    continue
                pid = str(record["player_id"])
                value = self.score_stats(pid, record["stats"])
                if value is None:
                    continue
                self.history_updates["projections"].append([w, pid, round(value, 3), "backfill"])
                if proj_src.get((w, pid)) != "snapshot":
                    proj[(w, pid)], proj_src[(w, pid)] = value, "backfill"
            for pid, stats in self._stat_records(entry.get("stats")):
                value = self.score_stats(pid, stats)
                opp = {k: stats[k] for k in fm_history.OPPORTUNITY_KEYS
                       if isinstance(stats.get(k), (int, float)) and not isinstance(stats.get(k), bool) and stats[k] != 0}
                if value is None and not opp:
                    continue
                self.history_updates["actuals"].append([w, pid, None if value is None else round(value, 3), "stats", opp])
                if opp:
                    usage[(w, pid)] = opp
                if value is not None and act_src.get((w, pid)) != "league":
                    act[(w, pid)], act_src[(w, pid)] = value, "stats"
            for entry_m in entry.get("matchups") or []:
                points = entry_m.get("players_points") if isinstance(entry_m, dict) else None
                if not isinstance(points, dict):
                    continue
                for pid, pts in points.items():
                    if isinstance(pts, (int, float)) and not isinstance(pts, bool):
                        self.history_updates["actuals"].append([w, str(pid), float(pts), "league", None])
                        act[(w, str(pid))], act_src[(w, str(pid))] = float(pts), "league"

        # Usage from nflverse for weeks the stats feed didn't cover.
        self.usage_sources: Dict[int, str] = {}
        for (w, _), u in usage.items():
            self.usage_sources.setdefault(w, "nflverse" if u.get("nflverse") else "sleeper")
        for wk, by_pid in sorted((hist.get("usage") or {}).items(), key=lambda kv: int(kv[0])):
            w = int(wk)
            for pid, u in (by_pid or {}).items():
                if fm_history.has_usage(usage.get((w, str(pid)))):
                    continue
                usage[(w, str(pid))] = u
                self.history_updates["actuals"].append([w, str(pid), None, "stats", u])
                self.usage_sources.setdefault(w, "nflverse")

        # This week's projections, recorded before each player's game starts.
        for pid, value in self.projection_points.items():
            if not self.is_locked(pid):
                self.history_updates["projections"].append([week, pid, round(value, 3), "snapshot"])

        per_pid: Dict[str, Dict[int, Tuple[Optional[float], Optional[float]]]] = {}
        for (w, pid), p in proj.items():
            if w < week:
                per_pid.setdefault(pid, {})[w] = (p, act.get((w, pid)))
        for (w, pid), a in act.items():
            if w < week and (w, pid) not in proj:
                per_pid.setdefault(pid, {})[w] = (None, a)
        self.history_usage = usage
        self.history_player_misses = {
            pid: [a - p for _, (p, a) in sorted(weeks.items()) if p is not None and a is not None and p >= 1.0]
            for pid, weeks in per_pid.items()}
        pairs = []
        sources = {"snapshot": 0, "backfill": 0}
        for pid, weeks in per_pid.items():
            for w, (p, a) in weeks.items():
                if p is not None and a is not None and p >= 1.0:
                    pairs.append((self.primary_position(pid), p, a))
                    sources[proj_src.get((w, pid), "backfill")] += 1
            form = fm_history.player_form(weeks)
            if form is not None:
                self.history_form[pid] = form
        weeks_with_data = sorted({w for (w, _) in act if w < week} | {w for (w, _) in proj if w < week})
        acc = fm_history.accuracy(pairs)
        self.history_accuracy = {pos: s for pos, s in acc["by_position"].items() if s}

        reason = None
        if not weeks_with_data:
            reason = ("No completed weeks yet this season." if not hist.get("weeks")
                      else "No past-week results could be loaded (see diagnostics).")
        elif acc["overall"] is None:
            reason = "Past results loaded, but no projections for those weeks to compare against."
        players = {}
        for pid in sorted(self.rostered):
            form = self.history_form.get(pid)
            if form is None:
                continue
            entry = {"name": self.player_name(pid), "position": self.primary_position(pid),
                     "team": self.player(pid).get("team"), "roster_id": self.rostered.get(pid)}
            entry.update(form)
            players[pid] = entry
        my_roster = self.roster_by_id(self.my_roster_id) or {}
        mine = [pid for pid in self.roster_active_players(my_roster) if pid in players]
        mine.sort(key=lambda pid: (-(players[pid]["avg_points"] or 0), self.player_name(pid)))
        return {
            "available": reason is None,
            "reason": reason,
            "weeks": weeks_with_data,
            "accuracy": acc,
            "min_projection": 1.0,
            "projection_sources": sources,
            "actual_sources": {s: sum(1 for (w, _), v in act_src.items() if w < week and v == s)
                               for s in ("league", "stats")},
            "stats_missing_weeks": list(hist.get("stats_missing") or []),
            "players": players,
            "my_roster": mine,
            "note": ("Projected vs actual points in your league's scoring. Projections recorded before "
                     "kickoff by earlier runs are used when available; otherwise the feed's projections "
                     "for past weeks are fetched afterwards."),
        }

    # -- opportunity: usage trends and breakout flags ---------------------
    def analyze_opportunity(self) -> Optional[dict]:
        """Snap share and targets + carries over recent weeks: free agents
        whose role is growing (breakouts) and my players losing theirs."""
        self.opportunity_trends: Dict[str, dict] = {}
        if not isinstance(self.bundle.get("history"), dict):
            return None
        usage = getattr(self, "history_usage", {}) or {}
        week = int(self.config.get("week") or 0)
        usage_weeks = sorted({w for (w, pid), u in usage.items() if w < week and fm_history.has_usage(u)})
        if len(usage_weeks) < 3:
            return {"available": False, "weeks": usage_weeks, "sources": {}, "breakouts": [], "declining": [],
                    "players": {},
                    "reason": ("Usage (snaps, targets, carries) is needed for at least 3 past weeks; "
                               "found %d." % len(usage_weeks))}
        # Teams with a game each week (byes are skipped, not counted as no role).
        teams_by_week: Dict[int, set] = {}
        for game in self.bundle.get("schedule") or []:
            if isinstance(game, dict) and str(game.get("week", "")).isdigit():
                teams_by_week.setdefault(int(game["week"]), set()).update(
                    str(game.get(k) or "").upper() for k in ("home", "away"))
        by_pid: Dict[str, Dict[int, Optional[dict]]] = {}
        for (w, pid), u in usage.items():
            if w in usage_weeks and fm_history.has_usage(u):
                by_pid.setdefault(pid, {})[w] = u
        my_roster = self.roster_by_id(self.my_roster_id) or {}
        mine = set(self.roster_active_players(my_roster))
        candidates = set(by_pid) | mine
        breakouts, declining, players = [], [], {}
        for pid in sorted(candidates):
            position = self.primary_position(pid)
            if position not in ("RB", "WR", "TE", "QB"):
                continue
            team = str(self.player(pid).get("team") or "").upper()
            weeks: Dict[int, Optional[dict]] = {}
            for w in usage_weeks:
                if w in by_pid.get(pid, {}):
                    weeks[w] = by_pid[pid][w]
                elif teams_by_week.get(w) and team and team not in teams_by_week[w]:
                    continue  # bye week
                else:
                    weeks[w] = None  # no recorded role that week
            tr = fm_history.trend(weeks)
            if tr is None or all(weeks[w] is None for w in tr["weeks"]):
                continue
            kind = fm_history.classify(tr) if position != "QB" else None
            entry = {"player_id": pid, "name": self.player_name(pid), "position": position,
                     "team": self.player(pid).get("team"), "rostered_by": self.team_name(self.rostered[pid])
                     if pid in self.rostered else None, "flag": kind, "note": fm_history.trend_note(tr)}
            entry.update(tr)
            self.opportunity_trends[pid] = entry
            if pid in mine:
                players[pid] = entry
            if kind == "breakout" and pid not in self.rostered and self.availability(pid)[0]:
                breakouts.append(entry)
            elif kind == "declining" and pid in mine:
                declining.append(entry)

        def growth(e: dict) -> Tuple[float, str]:
            snap = (e["snap_now"] or 0) - (e["snap_then"] or 0)
            opp = (e["opportunities_now"] or 0) - (e["opportunities_then"] or 0)
            return (-(snap + 2 * opp), e["player_id"])

        breakouts.sort(key=growth)
        declining.sort(key=lambda e: (growth(e)[0] * -1, e["player_id"]))
        sources = {}
        for w in usage_weeks:
            src = self.usage_sources.get(w, "sleeper")
            sources[src] = sources.get(src, 0) + 1
        return {
            "available": True, "reason": None, "weeks": usage_weeks,
            "sources": sources,
            "breakouts": breakouts[: self.top_n],
            "declining": declining,
            "players": players,
            "note": ("Earlier weeks vs the last two (of the last four with usage). Breakout: snap share up 15+ points "
                     "to 45%+, or targets + carries up by 4+ and half again. Losing role: snap share down 15+ points "
                     "from 40%+, or targets + carries down 4+ and by 40%."),
        }

    def player_pool(self) -> List[dict]:
        """Projected players at fantasy positions, for picking any-player trades."""
        rows = []
        for pid in self.open_pool("ppr"):
            info = self.player(pid)
            pts = {s: r2(sum(self.open_points(pid, w, s) or 0.0 for w in range(self.n_weeks)))
                   for s in ("ppr", "half", "std", "league")}
            rows.append({"player_id": pid, "name": self.player_name(pid), "position": self.primary_position(pid),
                         "team": info.get("team"), "injury_status": info.get("injury_status"), "window_points": pts})
        rows.sort(key=lambda r: (-(r["window_points"]["ppr"] or 0.0), r["name"]))
        return rows[:1500]

    def roster_summaries(self) -> List[dict]:
        """Every roster with its players, for building trades by hand."""
        out = []
        for roster in sorted(self.rosters, key=lambda r: r.get("roster_id") or 0):
            rid = roster.get("roster_id")
            players = []
            for pid in self.roster_active_players(roster):
                players.append({
                    "player_id": pid,
                    "name": self.player_name(pid),
                    "position": self.primary_position(pid),
                    "team": self.player(pid).get("team"),
                    "projection": r2(self.points(pid)) if self.has_projection(pid) else None,
                    "window_projection": r2(self.window_points(pid)),
                    "injury_status": self.player(pid).get("injury_status"),
                })
            order = {p: i for i, p in enumerate(("QB", "RB", "WR", "TE", "K", "DEF"))}
            players.sort(key=lambda p: (order.get(p["position"], 9), -(p["window_projection"] or 0), p["name"]))
            out.append({"roster_id": rid, "team": self.team_name(rid), "is_me": rid == self.my_roster_id,
                        "players": players})
        return out

    def run(self) -> dict:
        if not self.starting_slots:
            raise SystemExit("league has no starting slots in roster_positions")
        self.calculate_league_scoring()
        if int(self.config.get("horizon") or 0) > 0:
            self.score_future_weeks()
        else:
            self.window_weeks = [int(self.config.get("week") or 0)]
        my_roster = self.roster_by_id(self.my_roster_id)
        if my_roster is None:
            raise SystemExit("roster %s not found in league rosters" % self.my_roster_id)
        history = self.analyze_history()
        opportunity = self.analyze_opportunity()

        lineup = self.analyze_lineup(my_roster)
        matchup = self.analyze_matchup()
        if matchup is not None:
            matchup["win_probability"] = self.simulate_matchup(matchup, lineup)
        waivers = None if self.config.get("skip_waivers") else self.analyze_waivers(my_roster)
        if waivers is not None and self.history_form:
            for rows in waivers["groups"].values():
                for row in rows:
                    form = self.history_form.get(str(row.get("player_id")))
                    if form is not None:
                        row["recent"] = {k: form[k] for k in ("games", "avg_points", "avg_projection", "beat", "compared")}
                    tr = self.opportunity_trends.get(str(row.get("player_id"))) if opportunity else None
                    if tr is not None and tr.get("flag") == "breakout":
                        row.setdefault("notes", []).append("Role growing: " + tr["note"])
        trades = None if self.config.get("skip_trades") else self.analyze_trades(my_roster)
        custom_trades = self.analyze_custom_trades()
        value_trades = self.analyze_value_trades()

        projections_provenance = (self.provenance.get("projections") or {})
        report = {
            "schema_version": SCHEMA_VERSION,
            "metadata": {
                "tool_version": self.config.get("tool_version"),
                "generated_at": self.config.get("generated_at"),
                "league_id": self.config.get("league_id"),
                "league_name": self.league.get("name"),
                "username": self.config.get("username"),
                "user_id": self.config.get("user_id"),
                "roster_id": self.my_roster_id,
                "team_name": self.team_name(self.my_roster_id),
                "season": self.config.get("season"),
                "season_type": self.config.get("season_type"),
                "week": self.config.get("week"),
                "week_rolled_from": self.config.get("week_rolled_from"),
                "window_weeks": self.window_weeks,
                "horizon_mode": self.config.get("horizon_mode") or "weeks",
                "window_label": self.window_label(),
                "offline": bool(self.config.get("offline")),
                "top_n": self.config.get("top_n"),
                "churn_threshold": self.config.get("churn_threshold"),
                "fairness": self.config.get("fairness"),
                "read_only": True,
                "roster_positions": self.roster_positions,
                "starting_slots": self.starting_slots,
                "scoring": {
                    "mode": self.scoring_mode,
                    "source": self.scoring_source,
                    "unsupported_keys": self.unsupported_scoring_keys,
                    "position_fallback": self.position_fallback,
                },
                "projections": {
                    "url": projections_provenance.get("url"),
                    "source": projections_provenance.get("source"),
                    "fetched_at": projections_provenance.get("fetched_at"),
                    "cache_age_seconds": projections_provenance.get("cache_age_seconds"),
                    "stale": projections_provenance.get("source") == "stale-cache",
                    "record_count": len(self.projection_points),
                    "note": (
                        "Projection feed is not part of Sleeper's documented read-only "
                        "API and is treated as an unstable dependency."
                    ),
                },
                "players_source": (self.provenance.get("players") or {}).get("source"),
            },
            "warnings": self.warnings,
            "lineup": lineup,
            "matchup": matchup,
            "waivers": waivers,
            "trades": trades,
            "custom_trades": custom_trades,
            "value_trades": value_trades,
            "history": history,
            "opportunity": opportunity,
            "player_pool": self.player_pool(),
            "rosters": self.roster_summaries(),
            "diagnostics": {
                "fetches": self.bundle.get("diagnostics") or [],
                "trending_available": self.provenance.get("trending_available"),
                "transactions_available": self.provenance.get("transactions_available"),
                "schedule_available": self.schedule_available,
                "lock_source": self.lock_source,
                "players_cache_age_seconds": (self.provenance.get("players") or {}).get(
                    "cache_age_seconds"
                ),
                "read_only": True,
            },
        }
        return report


def main(argv: Optional[List[str]] = None) -> int:
    """Usage: fm_analysis.py [--in BUNDLE] [--out REPORT]  (default stdin/stdout).

    File paths avoid shell pipes, which re-encode text on Windows PowerShell.
    Output is ASCII-only JSON (non-ASCII characters are escaped)."""
    argv = list(sys.argv[1:] if argv is None else argv)
    in_path = out_path = None
    while argv:
        flag = argv.pop(0)
        if flag in ("--in", "--out") and argv:
            if flag == "--in":
                in_path = argv.pop(0)
            else:
                out_path = argv.pop(0)
        else:
            print("usage: fm_analysis.py [--in BUNDLE] [--out REPORT]", file=sys.stderr)
            return 2
    try:
        if in_path:
            with open(in_path, "r", encoding="utf-8-sig") as fh:
                bundle = json.load(fh)
        else:
            bundle = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print("invalid analysis bundle: %s" % exc, file=sys.stderr)
        return 1
    analyzer = Analyzer(bundle)
    report = analyzer.run()
    if out_path:
        with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(report, fh, indent=2, sort_keys=True)
            fh.write("\n")
    else:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
