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
                    "points=CASE WHEN actuals.source='league' THEN actuals.points "
                    "ELSE COALESCE(excluded.points, actuals.points) END",
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
# Usage from nflverse (fallback when the stats feed has no usage)
# --------------------------------------------------------------------------
USAGE_KEYS = ("off_snp", "rec_tgt", "rush_att", "snap_pct")
NFLVERSE_TEAMS = {"LA": "LAR"}  # nflverse code -> Sleeper code


def has_usage(stats) -> bool:
    return isinstance(stats, dict) and any(k in stats for k in USAGE_KEYS)


def norm_name(name: str) -> str:
    text = "".join(ch for ch in (name or "").lower() if ch.isalnum() or ch == " ")
    words = [w for w in text.split() if w not in ("jr", "sr", "ii", "iii", "iv", "v")]
    return " ".join(words)


def nflverse_usage(stats_rows: Iterable[dict], snap_rows: Iterable[dict], weeks: Sequence[int],
                   players: Dict[str, dict]) -> Tuple[Dict[int, Dict[str, dict]], int]:
    """Weekly usage per Sleeper player id from nflverse's weekly player stats
    (targets, carries, target share; GSIS ids) and snap counts (offense snap
    share; matched by name and team). Returns ({week: {pid: usage}}, matched)."""
    wanted = set(int(w) for w in weeks)
    by_gsis = {str(v.get("gsis_id")).strip(): pid for pid, v in players.items() if v.get("gsis_id")}
    by_name: Dict[Tuple[str, str], Optional[str]] = {}
    for pid, v in players.items():
        key = (norm_name(v.get("full_name") or ""), str(v.get("team") or "").upper())
        if key[0]:
            by_name[key] = None if key in by_name else pid  # ambiguous names match nobody
    out: Dict[int, Dict[str, dict]] = {w: {} for w in wanted}

    def week_of(row: dict) -> Optional[int]:
        try:
            w = int(row.get("week") or 0)
        except ValueError:
            return None
        return w if w in wanted else None

    def num(value) -> Optional[float]:
        try:
            return float(value) if value not in (None, "", "NA") else None
        except ValueError:
            return None

    for row in stats_rows:
        if (row.get("season_type") or "REG") != "REG":
            continue
        w = week_of(row)
        if w is None:
            continue
        team = NFLVERSE_TEAMS.get(row.get("team") or "", row.get("team") or "")
        pid = by_gsis.get((row.get("player_id") or "").strip()) or by_name.get(
            (norm_name(row.get("player_display_name") or row.get("player_name") or ""), team))
        if not pid:
            continue
        usage = out[w].setdefault(pid, {"nflverse": 1})
        for src, dst in (("targets", "rec_tgt"), ("carries", "rush_att"), ("target_share", "target_share")):
            value = num(row.get(src))
            if value:
                usage[dst] = round(value, 4)
    for row in snap_rows:
        if (row.get("game_type") or "REG") != "REG":
            continue
        w = week_of(row)
        pct = num(row.get("offense_pct"))
        if w is None or not pct:
            continue
        team = NFLVERSE_TEAMS.get(row.get("team") or "", row.get("team") or "")
        pid = by_name.get((norm_name(row.get("player") or ""), team))
        if not pid:
            continue
        usage = out[w].setdefault(pid, {"nflverse": 1})
        usage["snap_pct"] = round(pct, 4)
        snaps = num(row.get("offense_snaps"))
        if snaps:
            usage["off_snp"] = snaps
    matched = sum(len(v) for v in out.values())
    return {w: v for w, v in out.items() if v}, matched


# --------------------------------------------------------------------------
# Opportunity trends
# --------------------------------------------------------------------------
def usage_metrics(usage: Optional[dict]) -> Tuple[Optional[float], float, float, float]:
    """(snap share 0-1 or None, targets + carries, targets, carries)."""
    usage = usage or {}
    snap = usage.get("snap_pct")
    if snap is None and usage.get("off_snp") and usage.get("tm_off_snp"):
        snap = float(usage["off_snp"]) / float(usage["tm_off_snp"])
    targets = float(usage.get("rec_tgt") or 0)
    carries = float(usage.get("rush_att") or 0)
    return (None if snap is None else min(1.0, float(snap))), targets + carries, targets, carries


def trend(weeks: Dict[int, Optional[dict]], last_n: int = 4) -> Optional[dict]:
    """weeks: week -> usage (None = no role that week). Compares the earlier
    weeks of the last `last_n` with the most recent ones."""
    played = sorted(weeks)[-last_n:]
    if len(played) < 3:
        return None
    split = len(played) // 2
    early, recent = played[:split], played[split:]

    def avg(ws: Sequence[int], idx: int) -> Optional[float]:
        values = [usage_metrics(weeks[w])[idx] for w in ws]
        values = [v for v in values if v is not None]
        return sum(values) / len(values) if values else None

    snap_then, snap_now = avg(early, 0), avg(recent, 0)
    if snap_then is None or snap_now is None:
        snap_then = snap_now = None
    return {
        "weeks": played,
        "snap_then": None if snap_then is None else int(round(snap_then * 100)),
        "snap_now": None if snap_now is None else int(round(snap_now * 100)),
        "opportunities_then": _r(avg(early, 1), 1),
        "opportunities_now": _r(avg(recent, 1), 1),
        "targets_now": _r(avg(recent, 2), 1),
        "carries_now": _r(avg(recent, 3), 1),
    }


def classify(t: dict) -> Optional[str]:
    """'breakout', 'declining' or None for a trend from trend()."""
    st, sn = t.get("snap_then"), t.get("snap_now")
    ot, on = t.get("opportunities_then") or 0.0, t.get("opportunities_now") or 0.0
    if st is not None and sn is not None:
        if sn >= 45 and sn - st >= 15:
            return "breakout"
        if st >= 40 and st - sn >= 15 and on <= ot:
            return "declining"  # fewer snaps only matters if touches didn't rise
    if on >= 8 and on - ot >= 4 and on >= 1.5 * ot:
        return "breakout"
    if ot >= 6 and ot - on >= 4 and on <= 0.6 * ot:
        return "declining"
    return None


def trend_note(t: dict) -> str:
    parts = []
    if t.get("snap_then") is not None:
        parts.append("snaps %d%% -> %d%%" % (t["snap_then"], t["snap_now"]))
    parts.append("targets+carries %s -> %s a game" % (_fmt(t.get("opportunities_then")), _fmt(t.get("opportunities_now"))))
    return ", ".join(parts)


def _fmt(value: Optional[float]) -> str:
    if value is None:
        return "n/a"
    return str(int(value)) if float(value).is_integer() else "%.1f" % value


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
    # A week counts as a game when the player was projected to play (1+
    # points) or scored; byes and weeks without a role are left out.
    played = sorted(w for w, (p, a) in weeks.items()
                    if a is not None and ((p is not None and p >= 1.0) or a > 0))[-last_n:]
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
