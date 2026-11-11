"""Season history for fantasy_manager: weekly projections and actual points.

Two parts, both standard library only:

* HistoryStore - a small SQLite database (history.sqlite in the cache folder)
  holding league-scored projections and actual points per player and week,
  so past weeks are fetched once and pre-kickoff projections are kept.
* Pure statistics (accuracy, player_form) used by the analysis to measure
  how good the projections have been and how players have done lately.

The database is a cache of derived data: deleting it only costs a refetch of
the past weeks (snapshots of earlier pre-kickoff projections are lost).
"""

from __future__ import annotations

import json
import math
import sqlite3
import time
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

SCHEMA_VERSION = 1

# Opportunity stats kept with actual points (used for usage trends).
OPPORTUNITY_KEYS = (
    "off_snp", "tm_off_snp", "rec_tgt", "rush_att", "rec", "pass_att",
    "rush_rz_att", "rec_rz_tgt", "rush_yd", "rec_yd",
)


class HistoryStore:
    """Projections and actuals per (league, season, week, player).

    Projection source: 'snapshot' (recorded before kickoff by a run) or
    'backfill' (fetched afterwards). A snapshot is never overwritten.
    Actual source: 'league' (the league's own matchup points) or 'stats'
    (the stats feed scored with league rules). League points win.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self.db = sqlite3.connect(path, timeout=10)
        self.db.execute("PRAGMA journal_mode=WAL" if path != ":memory:" else "PRAGMA journal_mode=MEMORY")
        self._migrate()

    def close(self) -> None:
        self.db.close()

    def _migrate(self) -> None:
        cur = self.db.cursor()
        cur.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        row = cur.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
        if row is None:
            cur.executescript("""
                CREATE TABLE IF NOT EXISTS projections (
                    league_id TEXT, season TEXT, week INTEGER, player_id TEXT,
                    points REAL, source TEXT, recorded_at INTEGER,
                    PRIMARY KEY (league_id, season, week, player_id));
                CREATE TABLE IF NOT EXISTS actuals (
                    league_id TEXT, season TEXT, week INTEGER, player_id TEXT,
                    points REAL, source TEXT, stats TEXT, recorded_at INTEGER,
                    PRIMARY KEY (league_id, season, week, player_id));
                CREATE TABLE IF NOT EXISTS weeks (
                    league_id TEXT, season TEXT, week INTEGER,
                    projections_ok INTEGER DEFAULT 0, actuals_ok INTEGER DEFAULT 0,
                    stats_ok INTEGER DEFAULT 0, attempted_at INTEGER DEFAULT 0,
                    PRIMARY KEY (league_id, season, week));
            """)
            cur.execute("INSERT OR REPLACE INTO meta VALUES ('schema_version', ?)", (str(SCHEMA_VERSION),))
        self.db.commit()

    # -- reading ------------------------------------------------------------
    def week_status(self, league_id: str, season: str) -> Dict[int, dict]:
        rows = self.db.execute(
            "SELECT week, projections_ok, actuals_ok, stats_ok, attempted_at FROM weeks "
            "WHERE league_id=? AND season=?", (league_id, season)).fetchall()
        return {r[0]: {"projections_ok": bool(r[1]), "actuals_ok": bool(r[2]), "stats_ok": bool(r[3]),
                       "attempted_at": r[4]} for r in rows}

    def load(self, league_id: str, season: str) -> dict:
        proj = [[r[0], r[1], r[2], r[3]] for r in self.db.execute(
            "SELECT week, player_id, points, source FROM projections WHERE league_id=? AND season=? "
            "ORDER BY week, player_id", (league_id, season))]
        act = [[r[0], r[1], r[2], r[3], json.loads(r[4]) if r[4] else {}] for r in self.db.execute(
            "SELECT week, player_id, points, source, stats FROM actuals WHERE league_id=? AND season=? "
            "ORDER BY week, player_id", (league_id, season))]
        return {"projections": proj, "actuals": act}

    # -- writing ------------------------------------------------------------
    def save(self, league_id: str, season: str, updates: dict) -> None:
        now = int(time.time())
        cur = self.db.cursor()
        for week, pid, points, source in updates.get("projections") or []:
            if source == "snapshot":
                cur.execute("INSERT OR REPLACE INTO projections VALUES (?,?,?,?,?,?,?)",
                            (league_id, season, week, pid, points, source, now))
            else:  # backfill never replaces a snapshot
                cur.execute("INSERT OR IGNORE INTO projections VALUES (?,?,?,?,?,?,?)",
                            (league_id, season, week, pid, points, source, now))
        for week, pid, points, source, stats in updates.get("actuals") or []:
            blob = json.dumps(stats, sort_keys=True) if stats else None
            if source == "league":
                cur.execute(
                    "INSERT INTO actuals VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(league_id, season, week, player_id) "
                    "DO UPDATE SET points=excluded.points, source='league', "
                    "stats=COALESCE(excluded.stats, actuals.stats), recorded_at=excluded.recorded_at",
                    (league_id, season, week, pid, points, source, blob, now))
            else:  # stats-feed points never replace league points, but add usage stats
                cur.execute(
                    "INSERT INTO actuals VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(league_id, season, week, player_id) "
                    "DO UPDATE SET stats=COALESCE(excluded.stats, actuals.stats), "
                    "points=CASE WHEN actuals.source='league' THEN actuals.points ELSE excluded.points END",
                    (league_id, season, week, pid, points, source, blob, now))
        for week, parts in (updates.get("weeks") or {}).items():
            cur.execute("INSERT OR IGNORE INTO weeks (league_id, season, week) VALUES (?,?,?)",
                        (league_id, season, int(week)))
            cur.execute(
                "UPDATE weeks SET projections_ok=MAX(projections_ok, ?), actuals_ok=MAX(actuals_ok, ?), "
                "stats_ok=MAX(stats_ok, ?), attempted_at=? WHERE league_id=? AND season=? AND week=?",
                (int(bool(parts.get("projections_ok"))), int(bool(parts.get("actuals_ok"))),
                 int(bool(parts.get("stats_ok"))), now, league_id, season, int(week)))
        self.db.commit()


# --------------------------------------------------------------------------
# Statistics
# --------------------------------------------------------------------------
def _r(value: Optional[float], digits: int = 2) -> Optional[float]:
    return None if value is None else round(value, digits)


def summarize(errors: Sequence[float]) -> Optional[dict]:
    """Errors are actual - projected. Returns MAE, RMSE, bias, spread, hit rate."""
    n = len(errors)
    if n == 0:
        return None
    mean = sum(errors) / n
    mae = sum(abs(e) for e in errors) / n
    rmse = math.sqrt(sum(e * e for e in errors) / n)
    sd = math.sqrt(sum((e - mean) ** 2 for e in errors) / (n - 1)) if n > 1 else None
    within = sum(1 for e in errors if abs(e) <= 5.0) / n
    return {"n": n, "mae": _r(mae), "rmse": _r(rmse), "bias": _r(mean), "sd": _r(sd),
            "within_5_pct": int(round(within * 100))}


def accuracy(pairs: Iterable[Tuple[str, float, float]], min_projection: float = 1.0) -> dict:
    """pairs: (position, projected, actual). Player-weeks projected below
    `min_projection` (backups, players not expected to play) are skipped."""
    by_pos: Dict[str, List[float]] = {}
    overall: List[float] = []
    for position, projected, actual in pairs:
        if projected is None or actual is None or projected < min_projection:
            continue
        err = actual - projected
        by_pos.setdefault(position or "?", []).append(err)
        overall.append(err)
    return {"overall": summarize(overall),
            "by_position": {pos: summarize(errs) for pos, errs in sorted(by_pos.items())}}


def player_form(weeks: Dict[int, Tuple[Optional[float], Optional[float]]], last_n: int = 4) -> Optional[dict]:
    """weeks: week -> (projected, actual). Uses the last `last_n` weeks with
    an actual score."""
    played = sorted(w for w, (_, a) in weeks.items() if a is not None)[-last_n:]
    if not played:
        return None
    actuals = [weeks[w][1] for w in played]
    paired = [(weeks[w][0], weeks[w][1]) for w in played if weeks[w][0] is not None]
    return {
        "weeks": played,
        "games": len(played),
        "avg_points": _r(sum(actuals) / len(actuals), 1),
        "avg_projection": _r(sum(p for p, _ in paired) / len(paired), 1) if paired else None,
        "beat": sum(1 for p, a in paired if a > p),
        "compared": len(paired),
        "last": [{"week": w, "projection": _r(weeks[w][0], 1), "actual": _r(weeks[w][1], 1)} for w in played],
    }
