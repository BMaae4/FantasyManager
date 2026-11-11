#!/usr/bin/env python3
"""compare_reports.py EXPECTED ACTUAL -> exit 0 when the two reports match,
ignoring timestamps (generated_at, fetched_at, per-fetch 'at')."""
import json
import sys


def normalise(path):
    with open(path, "r", encoding="utf-8-sig") as fh:
        report = json.load(fh)
    report.get("metadata", {}).pop("generated_at", None)
    report.get("metadata", {}).get("projections", {}).pop("fetched_at", None)
    for fetch in report.get("diagnostics", {}).get("fetches", []):
        fetch.pop("at", None)
    return report


def diff(a, b, path="$"):
    if type(a) is not type(b) and not (isinstance(a, (int, float)) and isinstance(b, (int, float))):
        return "%s: %r != %r" % (path, a, b)
    if isinstance(a, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                return "%s.%s: present in only one report" % (path, key)
            found = diff(a[key], b[key], "%s.%s" % (path, key))
            if found:
                return found
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return "%s: length %d != %d" % (path, len(a), len(b))
        for i, (x, y) in enumerate(zip(a, b)):
            found = diff(x, y, "%s[%d]" % (path, i))
            if found:
                return found
        return None
    if (".win_probability" in path and isinstance(a, (int, float)) and isinstance(b, (int, float))
            and abs(a - b) <= 0.0101):
        return None  # simulated: allow last-digit differences between platforms' math libraries
    return None if a == b else "%s: %r != %r" % (path, a, b)


if __name__ == "__main__":
    problem = diff(normalise(sys.argv[1]), normalise(sys.argv[2]))
    if problem:
        print(problem)
        sys.exit(1)
