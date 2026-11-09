#!/usr/bin/env python3
"""JSON helpers for the PowerShell front end (FantasyManager.ps1).

They do what fantasy_manager.sh does with jq, so both front ends validate and
assemble data identically. Windows PowerShell 5.1 cannot parse JSON larger
than ~2 MB (the Sleeper player database is ~5 MB), so large files are handled
here. Standard library only.

Commands (exit 0 = ok, 1 = invalid / unavailable, 2 = usage):
  check FILE object|array [projections|schedule]
      Valid JSON of the given type and non-empty; optional shape check.
      Prints the record count.
  week-state SCHEDULE WEEK
      Prints complete | started | upcoming | unknown.
  bundle DIR META OUT
      Writes the analysis bundle from DIR/*.json plus META (config,
      provenance, warnings, future_weeks); same layout as the bash bundle.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any


def load(path: str) -> Any:
    with open(path, "r", encoding="utf-8-sig") as fh:
        return json.load(fh)


def check(path: str, want: str, shape: str | None) -> int:
    try:
        data = load(path)
    except (OSError, ValueError) as exc:
        print("not valid JSON: %s" % exc, file=sys.stderr)
        return 1
    actual = "object" if isinstance(data, dict) else "array" if isinstance(data, list) else type(data).__name__
    if actual != want:
        print("expected JSON %s, got %s" % (want, actual), file=sys.stderr)
        return 1
    if len(data) == 0:
        print("%s is empty" % want, file=sys.stderr)
        return 1
    if shape == "projections":
        if not any(isinstance(r, dict) and "player_id" in r and isinstance(r.get("stats"), dict) for r in data):
            print("no records with player_id and object stats", file=sys.stderr)
            return 1
    elif shape == "schedule":
        keys = ("week", "home", "away", "status")
        if not any(isinstance(r, dict) and all(k in r for k in keys) for r in data):
            print("no records with week/home/away/status", file=sys.stderr)
            return 1
    print(len(data))
    return 0


def week_state(path: str, week: str) -> int:
    try:
        games = load(path)
    except (OSError, ValueError):
        print("unknown")
        return 0
    statuses = [
        str(g.get("status") or "").lower()
        for g in games
        if isinstance(g, dict) and str(g.get("week", "")) == str(week)
    ]
    if not statuses:
        state = "unknown"
    elif all(s == "complete" for s in statuses):
        state = "complete"
    elif any(s in ("complete", "in_game") for s in statuses):
        state = "started"
    else:
        state = "upcoming"
    print(state)
    return 0


def slim_players(players: dict) -> dict:
    """Same fields and name handling as the jq slimming in fantasy_manager.sh."""
    out = {}
    for key, value in players.items():
        value = value if isinstance(value, dict) else {}
        name = value.get("full_name")
        if name is None or name is False:
            name = (value.get("first_name") or "") + " " + (value.get("last_name") or "")
        if isinstance(name, str):
            name = name.strip(" ")
        out[key] = {
            "player_id": value.get("player_id") or key,
            "full_name": name,
            "position": value.get("position"),
            "fantasy_positions": value.get("fantasy_positions") or [],
            "team": value.get("team"),
            "status": value.get("status"),
            "injury_status": value.get("injury_status"),
            "injury_notes": value.get("injury_notes"),
            "practice_participation": value.get("practice_participation"),
            "active": value.get("active"),
            "years_exp": value.get("years_exp"),
            "depth_chart_position": value.get("depth_chart_position"),
            "depth_chart_order": value.get("depth_chart_order"),
            "news_updated": value.get("news_updated"),
        }
    return out


def bundle(directory: str, meta_path: str, out_path: str) -> int:
    meta = load(meta_path)

    def part(name: str, default: Any = None) -> Any:
        path = os.path.join(directory, name + ".json")
        return load(path) if os.path.exists(path) else default

    future = {}
    for week in meta.get("future_weeks") or []:
        data = part("projections_w%s" % week)
        if isinstance(data, list):
            future[str(week)] = data
    result = {
        "config": meta.get("config") or {},
        "provenance": meta.get("provenance") or {},
        "warnings": meta.get("warnings") or [],
        "league": part("league", {}),
        "rosters": part("rosters", []),
        "users": part("users", []),
        "matchups": part("matchups", []),
        "players": slim_players(part("players", {}) or {}),
        "projections": part("projections", []),
        "trending_add": part("trending_add", []),
        "transactions": part("transactions", []),
        "diagnostics": meta.get("diagnostics") or [],
        "schedule": part("schedule", []),
        "future_projections": future,
    }
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(result, fh)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[0] == "check":
        return check(argv[1], argv[2], argv[3] if len(argv) > 3 else None)
    if len(argv) == 3 and argv[0] == "week-state":
        return week_state(argv[1], argv[2])
    if len(argv) == 4 and argv[0] == "bundle":
        return bundle(argv[1], argv[2], argv[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
