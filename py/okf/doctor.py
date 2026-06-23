"""okf doctor (Python) — mirrors r/okf/R/okf_doctor.R.

A DETERMINISTIC health/maintenance report for a bundle (reusing the validation
findings in the catalog plus maintenance checks), with a health score and
CI-friendly counts. `doctor_fix` applies ONLY unambiguously-safe repairs to the
source files (normalize parseable non-ISO timestamps; re-point a broken link
when exactly one basename matches) and reports every change. No LLM, no guessing.
"""
from __future__ import annotations
import datetime, os, re
from typing import Optional

from . import okf as _okf
from .html import _relpath

_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def doctor(con, now: Optional[str] = None, stale_days: Optional[int] = None) -> dict:
    """Health/maintenance report. Combines catalog validation findings with
    maintenance checks (duplicate titles; future/stale timestamps when `now` is
    given). Health `score` = percent of non-reserved concepts with zero findings.
    Returns a dict: score, n_concepts, n_healthy, n_error, n_warn, by_rule, issues."""
    cps = con.execute(
        "SELECT path, reserved, title, timestamp FROM okf_concept ORDER BY path").fetchall()
    nonres = [r for r in cps if not r[1]]
    issues = [{"path": p, "severity": s, "rule": ru, "message": m}
              for p, s, ru, m in con.execute(
                  "SELECT path, severity, rule, message FROM okf_validation").fetchall()]

    # duplicate titles among non-reserved concepts
    titles = {}
    for path, _, title, _ in nonres:
        if title:
            titles.setdefault(title, []).append(path)
    for title, paths in titles.items():
        if len(paths) > 1:
            for p in paths:
                issues.append({"path": p, "severity": "warn", "rule": "duplicate_title",
                               "message": f"title shared with another concept: {title}"})

    # future / stale timestamps (only with a reference time)
    if now:
        try:
            now_t = datetime.datetime.strptime(now, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            now_t = None
        if now_t:
            for path, _, _, ts in nonres:
                if not ts or not _ISO.match(ts):
                    continue
                tv = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                if tv > now_t:
                    issues.append({"path": path, "severity": "warn", "rule": "future_timestamp",
                                   "message": f"timestamp is in the future: {ts}"})
                elif stale_days is not None and (now_t - tv).days > stale_days:
                    issues.append({"path": path, "severity": "warn", "rule": "stale_timestamp",
                                   "message": f"timestamp older than {int(stale_days)} days: {ts}"})

    flagged = {i["path"] for i in issues}
    n = len(nonres)
    healthy = sum(1 for r in nonres if r[0] not in flagged)
    score = round(100 * healthy / n) if n else 100
    by_rule = {}
    for i in issues:
        by_rule[i["rule"]] = by_rule.get(i["rule"], 0) + 1
    issues.sort(key=lambda i: (i["severity"], i["path"]))
    return {"score": score, "n_concepts": n, "n_healthy": healthy,
            "n_error": sum(1 for i in issues if i["severity"] == "error"),
            "n_warn": sum(1 for i in issues if i["severity"] == "warn"),
            "by_rule": by_rule, "issues": issues}


def _to_iso(s: str) -> Optional[str]:
    """Parse a loosely-formatted date/time to ISO-8601 UTC, or None if ambiguous."""
    s = s.strip()
    if _ISO.match(s):
        return s
    for f in ("%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.datetime.strptime(s, f).strftime("%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            pass
    for f in ("%Y-%m-%d", "%Y/%m/%d", "%m/%d/%Y", "%d %b %Y", "%B %d, %Y"):
        try:
            return datetime.datetime.strptime(s, f).strftime("%Y-%m-%dT00:00:00Z")
        except ValueError:
            pass
    return None


def doctor_fix(root: str) -> list:
    """Apply only unambiguously-safe maintenance fixes to a bundle's files:
    normalize a parseable non-ISO `timestamp:`; re-point a broken link whose
    basename matches exactly one concept. Edits in place; returns a list of
    {path, kind, before, after}. Ambiguous cases are left for `doctor` to report."""
    b = _okf.read_bundle(root)
    lk = _okf.links(b)
    known = list(b.known)
    changes = []

    def fpath(rel):
        return os.path.join(root, rel)

    # 1) timestamp normalization (frontmatter line)
    for c in b.concepts:
        if c.reserved or not c.timestamp:
            continue
        iso = _to_iso(c.timestamp)
        if not iso or iso == c.timestamp:
            continue
        with open(fpath(c.path), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        fences = [i for i, ln in enumerate(lines) if re.match(r"^---\s*$", ln)]
        if len(fences) < 2:
            continue
        for i in range(fences[0] + 1, fences[1]):
            if re.match(r"^\s*timestamp\s*:", lines[i]):
                lines[i] = re.sub(r"(^\s*timestamp\s*:\s*).*$", r"\g<1>" + iso, lines[i])
                with open(fpath(c.path), "w", encoding="utf-8") as fh:
                    fh.write("\n".join(lines) + "\n")
                changes.append({"path": c.path, "kind": "timestamp",
                                "before": c.timestamp, "after": iso})
                break

    # 2) moved-link repair (unique basename match)
    base_of = lambda p: os.path.basename(p.split("#", 1)[0])
    bn = {}
    for k in known:
        bn.setdefault(base_of(k), []).append(k)
    for link in lk:
        if link["resolved"]:
            continue
        raw, src = link["dst_raw"], link["src_path"]
        b0 = base_of(raw)
        match = bn.get(b0, [])
        if not b0 or len(match) != 1:
            continue
        d = os.path.dirname(src)
        frag = raw[len(raw.split("#", 1)[0]):]
        newrel = _relpath(d, match[0]) + frag
        with open(fpath(src), encoding="utf-8") as fh:
            txt = fh.read()
        needle, repl = f"]({raw})", f"]({newrel})"
        if needle not in txt:
            continue
        with open(fpath(src), "w", encoding="utf-8") as fh:
            fh.write(txt.replace(needle, repl))
        changes.append({"path": src, "kind": "link", "before": raw, "after": newrel})

    return changes
