#!/usr/bin/env python3
"""Analysis engine for fantasy_manager.sh.

Reads one bundle JSON object on stdin (league, rosters, users, matchups,
players, projections, activity, provenance) and writes one canonical report
JSON object on stdout.  Standard library only.

The engine never prints human readable output and never performs network
calls; rendering happens in fantasy_manager.sh.
"""

from __future__ import annotations

import json
import sys
from itertools import combinations
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

SCHEMA_VERSION = "1.0"

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
BLOCKING_INJURY = {"out", "ir", "pup", "suspended", "doubtful", "na"}
RISK_INJURY = {"questionable", "doubtful", "limited participation", "did not participate"}

AGGREGATE_FALLBACK_FIELDS = ("pts_ppr", "pts_half_ppr", "pts_std")

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
        self.projection_stats: Dict[str, dict] = {}
        self.scoring_mode = "unknown"
        self.scoring_source = "unknown"
        self.unsupported_scoring_keys: List[str] = []
        self._optimize_cache: Dict[Tuple[str, ...], Tuple[float, Dict[int, str]]] = {}

        self.rostered: Dict[str, int] = {}
        for roster in self.rosters:
            for pid in self._roster_all_players(roster):
                self.rostered[pid] = roster.get("roster_id")

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

    def points(self, pid: str) -> float:
        return float(self.projection_points.get(str(pid), 0.0))

    def has_projection(self, pid: str) -> bool:
        return str(pid) in self.projection_points

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
            if unsupported:
                self.warn(
                    "%d league scoring categories have no matching projection stat "
                    "and are excluded: %s"
                    % (len(unsupported), ", ".join(unsupported[:25]))
                )
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
    ) -> Dict[Tuple[int, str], int]:
        incumbents = incumbents or {}
        order = sorted(candidates, key=lambda p: (-self.points(p), str(p)))
        tiebreak = {pid: len(order) - idx for idx, pid in enumerate(order)}
        weights: Dict[Tuple[int, str], int] = {}
        for i, slot in enumerate(slots):
            for pid in candidates:
                if not self.eligible(slot, pid):
                    continue
                points_milli = int(round(self.points(pid) * 1000))
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
    ) -> Tuple[float, Dict[int, str]]:
        slots = list(slots if slots is not None else self.starting_slots)
        candidates = sorted({str(p) for p in player_ids})
        if filter_available:
            candidates = [p for p in candidates if self.availability(p)[0]]
        cache_key = tuple(["|".join(slots)] + candidates + ["inc:%s" % sorted((incumbents or {}).items())])
        cached = self._optimize_cache.get(cache_key)
        if cached is not None:
            return cached
        weights = self.build_weights(slots, candidates, incumbents)
        assignment = assign_slots(slots, candidates, weights)
        total = sum(self.points(pid) for pid in assignment.values())
        result = (total, assignment)
        self._optimize_cache[cache_key] = result
        return result

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
        optimal_points, optimal = self.optimize(usable, incumbents=valid_incumbents)

        recommended_ids = set(optimal.values())
        current_ids = set(current.values())
        slots_out = []
        for index, slot in enumerate(self.starting_slots):
            cur = current.get(index)
            rec = optimal.get(index)
            cur_points = self.points(cur) if cur else 0.0
            rec_points = self.points(rec) if rec else 0.0
            gain = rec_points - cur_points
            if cur == rec and rec is not None:
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
                    "below_threshold": bool(action != "KEEP" and abs(gain) < self.threshold),
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

        actions = [s for s in slots_out if s["action"] != "KEEP"]
        return {
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

        my_projected = projected(mine)
        opp_projected = projected(opponent)
        differential = None
        if my_projected is not None and opp_projected is not None:
            differential = my_projected - opp_projected
        return {
            "matchup_id": matchup_id,
            "my_team": self.team_name(self.my_roster_id),
            "opponent_roster_id": opponent.get("roster_id") if opponent else None,
            "opponent_team": self.team_name(opponent.get("roster_id")) if opponent else None,
            "my_projected": r2(my_projected),
            "opponent_projected": r2(opp_projected),
            "differential": r2(differential),
            "my_points": r2(mine.get("points")) if isinstance(mine.get("points"), (int, float)) else None,
            "opponent_points": r2(opponent.get("points")) if opponent and isinstance(opponent.get("points"), (int, float)) else None,
            "note": (
                "Projection-only optimisation: correlation, game script and "
                "opponent defensive matchups are not modelled."
            ),
        }

    # -- waivers ----------------------------------------------------------
    def league_positions(self) -> List[str]:
        positions = set()
        for slot in self.starting_slots:
            positions.update(SLOT_ELIGIBILITY.get(slot.upper(), ()))
        return sorted(positions)

    def replacement_levels(self) -> Dict[str, float]:
        num_teams = len(self.rosters) or int(self.league.get("total_rosters") or 0) or 1
        slot_counts: Dict[str, int] = {}
        for slot in self.starting_slots:
            for position in SLOT_ELIGIBILITY.get(slot.upper(), ()):
                slot_counts[position] = slot_counts.get(position, 0) + 1
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
            index = min(len(pool) - 1, max(0, num_teams * slot_counts.get(position, 1) - 1))
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
        baseline, baseline_lineup = self.optimize(usable)

        settings = self.league.get("settings") or {}
        waiver_type_raw = settings.get("waiver_type")
        budget = settings.get("waiver_budget")
        roster_settings = roster.get("settings") or {}
        used = roster_settings.get("waiver_budget_used")
        remaining = None
        if isinstance(budget, (int, float)):
            remaining = float(budget) - float(used or 0)
        if waiver_type_raw == 2 or (isinstance(budget, (int, float)) and budget > 0):
            waiver_type = "FAAB"
        elif waiver_type_raw in (0, 1):
            waiver_type = "waiver priority"
        else:
            waiver_type = "unknown"
            self.warn("League waiver type could not be determined from league settings.")

        candidates_all = [
            pid
            for pid in self.projection_points
            if pid not in self.rostered and (set(self.player_positions(pid)) & positions)
        ]
        candidates_all.sort(key=lambda p: (-self.points(p), str(p)))
        shortlist = candidates_all[: max(self.top_n * 6, 40)]

        droppable = [
            pid
            for pid in sorted(usable, key=lambda p: (self.points(p), str(p)))
            if pid not in set(baseline_lineup.values())
        ][:10]
        if not droppable:
            droppable = sorted(usable, key=lambda p: (self.points(p), str(p)))[:5]

        rows = []
        for pid in shortlist:
            startable, notes = self.availability(pid)
            info = self.player(pid)
            with_candidate, with_lineup = self.optimize(list(usable) + [pid])
            lineup_gain = with_candidate - baseline
            best_drop = None
            best_value = None
            if startable:
                for drop in droppable:
                    if drop == pid:
                        continue
                    value, _ = self.optimize([p for p in usable if p != drop] + [pid])
                    key = (-value, self.points(drop), str(drop))
                    best_key = (
                        None
                        if best_drop is None
                        else (-best_value, self.points(best_drop), str(best_drop))
                    )
                    if best_key is None or key < best_key:
                        best_value = value
                        best_drop = drop
            net_gain = (best_value - baseline) if best_value is not None else lineup_gain
            position = self.primary_position(pid)
            rows.append(
                {
                    "player_id": pid,
                    "name": self.player_name(pid),
                    "position": position,
                    "team": info.get("team"),
                    "projection": r2(self.points(pid)),
                    "replacement_level": r2(replacement.get(position)) if position in replacement else None,
                    "replacement_advantage": r2(self.points(pid) - replacement[position])
                    if position in replacement
                    else None,
                    "lineup_gain": r2(lineup_gain),
                    "net_gain": r2(net_gain),
                    "would_start_this_week": pid in set(with_lineup.values()),
                    "drop_candidate": self.player_ref(best_drop) if best_drop else None,
                    "depth_chart_position": info.get("depth_chart_position"),
                    "depth_chart_order": info.get("depth_chart_order"),
                    "trending_adds_24h": trending.get(pid),
                    "available": startable,
                    "notes": notes,
                    "rest_of_season_value": None,
                }
            )

        components = {"roster_improvement": True}
        components["opportunity"] = any(r["depth_chart_order"] is not None for r in rows)
        components["add_trend"] = bool(trending) and any(r["trending_adds_24h"] is not None for r in rows)
        components["rest_of_season_value"] = False
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
        max_trend = max([r["trending_adds_24h"] or 0 for r in rows], default=0)
        for row in rows:
            score = 0.0
            if "roster_improvement" in weights_used:
                value = (row["net_gain"] or 0.0) / max_net if max_net > 0 else 0.0
                score += weights_used["roster_improvement"] * max(0.0, min(1.0, value))
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
            if waiver_type == "FAAB" and remaining is not None and row["available"]:
                fraction = max(0.0, min(0.35, (row["net_gain"] or 0.0) / 20.0))
                bid = int(round(remaining * fraction))
                if (row["net_gain"] or 0.0) > 0:
                    bid = max(1, bid)
                row["suggested_bid"] = bid
                row["suggested_bid_pct"] = int(round(100 * bid / remaining)) if remaining > 0 else None
                row["bid_basis"] = "estimate from net projected gain and remaining budget"
            else:
                row["suggested_bid"] = None
                row["suggested_bid_pct"] = None
                row["bid_basis"] = None
            if waiver_type == "waiver priority":
                row["use_priority"] = bool(row["available"] and (row["net_gain"] or 0) >= 1.0)
            else:
                row["use_priority"] = None

        def sort_key(row: dict):
            return (-(row.get("score") or 0.0), -(row.get("net_gain") or 0.0), row["name"])

        avoid = sorted(
            [r for r in rows if not r["available"] or not self.has_projection(r["player_id"])],
            key=sort_key,
        )[: self.top_n]
        available_rows = [r for r in rows if r["available"] and self.has_projection(r["player_id"])]
        priority = sorted(
            [r for r in available_rows if r["would_start_this_week"] and (r["net_gain"] or 0) >= 1.0],
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
                and (r["net_gain"] or 0) > 0
            ],
            key=sort_key,
        )[: self.top_n]

        return {
            "waiver": {
                "type": waiver_type,
                "budget": budget if isinstance(budget, (int, float)) else None,
                "remaining": remaining,
                "note": "Bid suggestions are estimates, not market data.",
            },
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
    def positional_starter_points(self, assignment: Dict[int, str]) -> Dict[str, float]:
        result: Dict[str, float] = {}
        for index, pid in assignment.items():
            slot = self.starting_slots[index]
            position = self.primary_position(pid) or slot
            result[position] = round(result.get(position, 0.0) + self.points(pid), 2)
        return result

    def roster_profile(self, roster: dict) -> dict:
        usable = self.roster_active_players(roster)
        total, assignment = self.optimize(usable)
        starters = set(assignment.values())
        replacement = self.replacement_levels()
        bench_above_replacement = 0.0
        entries = []
        for pid in usable:
            position = self.primary_position(pid)
            level = replacement.get(position)
            above = self.points(pid) - level if level is not None else None
            if pid not in starters and above is not None and above > 0:
                bench_above_replacement += above
            if not self.availability(pid)[0]:
                continue
            without, _ = self.optimize([p for p in usable if p != pid])
            cost = total - without
            entries.append(
                {
                    "player_id": pid,
                    "name": self.player_name(pid),
                    "position": position,
                    "projection": r2(self.points(pid)),
                    "lineup_cost": r2(cost),
                    "above_replacement": r2(above),
                }
            )
        entries.sort(key=lambda s: (-(s["projection"] or 0.0), s["name"]))
        # Surplus: a player the roster can lose without weakening its optimal
        # lineup by more than half a projected point.
        surplus = [e for e in entries if (e["lineup_cost"] or 0.0) <= 0.5]
        return {
            "roster_id": roster.get("roster_id"),
            "team": self.team_name(roster.get("roster_id")),
            "optimal_points": r2(total),
            "starters": starters,
            "usable": usable,
            "depth": self.positional_starter_points(assignment),
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
                return sum(self.points(entry["player_id"]) for entry in side)

            def evaluate(give: List[dict], get: List[dict]) -> Optional[dict]:
                give_ids = {g["player_id"] for g in give}
                get_ids = {g["player_id"] for g in get}
                my_after, _ = self.optimize(
                    [p for p in mine["usable"] if p not in give_ids] + sorted(get_ids)
                )
                their_after, _ = self.optimize(
                    [p for p in theirs["usable"] if p not in get_ids] + sorted(give_ids)
                )
                my_gain = my_after - my_base
                their_gain = their_after - their_base
                if my_gain <= 0 or their_gain <= 0:
                    return None
                value_out = exchange_value(give)
                value_in = exchange_value(get)
                gap = abs(value_out - value_in)
                largest = max(value_out, value_in)
                # Fair when the exchanged weekly projection is within the
                # tolerance of the larger side, or within one projected point.
                if gap > max(1.0, self.fairness * largest):
                    return None
                if (give_ids & mine["starters"]) and my_gain < 1.0:
                    return None  # protect core starters unless the return is material
                return {
                    "give": [
                        {"player_id": g["player_id"], "name": g["name"], "position": g["position"],
                         "projection": g["projection"]}
                        for g in give
                    ],
                    "get": [
                        {"player_id": g["player_id"], "name": g["name"], "position": g["position"],
                         "projection": g["projection"]}
                        for g in get
                    ],
                    "my_gain": r2(my_gain),
                    "their_gain": r2(their_gain),
                    "value_given": r2(value_out),
                    "value_received": r2(value_in),
                    "fairness_gap": r2(gap),
                    "my_depth_after": {k: r2(v) for k, v in
                                       self.positional_starter_points(
                                           self.optimize([p for p in mine["usable"] if p not in give_ids]
                                                         + sorted(get_ids))[1]).items()},
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
            "partners": [p for p in partners if p["packages"]],
        }

    # -- report -----------------------------------------------------------
    def run(self) -> dict:
        if not self.starting_slots:
            raise SystemExit("league has no starting slots in roster_positions")
        self.calculate_league_scoring()
        my_roster = self.roster_by_id(self.my_roster_id)
        if my_roster is None:
            raise SystemExit("roster %s not found in league rosters" % self.my_roster_id)

        lineup = self.analyze_lineup(my_roster)
        matchup = self.analyze_matchup()
        waivers = None if self.config.get("skip_waivers") else self.analyze_waivers(my_roster)
        trades = None if self.config.get("skip_trades") else self.analyze_trades(my_roster)

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
            "diagnostics": {
                "fetches": self.bundle.get("diagnostics") or [],
                "trending_available": self.provenance.get("trending_available"),
                "transactions_available": self.provenance.get("transactions_available"),
                "players_cache_age_seconds": (self.provenance.get("players") or {}).get(
                    "cache_age_seconds"
                ),
                "read_only": True,
            },
        }
        return report


def main() -> int:
    try:
        bundle = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print("invalid analysis bundle: %s" % exc, file=sys.stderr)
        return 1
    analyzer = Analyzer(bundle)
    report = analyzer.run()
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
