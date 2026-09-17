"""okf doctor (Python) — mirrors r/okf/R/okf_doctor.R.

A DETERMINISTIC health/maintenance report for a bundle (reusing the validation
findings in the catalog plus maintenance checks), with a health score and
CI-friendly counts. `doctor_fix` applies ONLY unambiguously-safe repairs to the
source files (normalize parseable non-ISO timestamps; re-point a broken link
when exactly one basename matches) and reports every change. No LLM, no guessing.
"""
from __future__ import annotations
import datetime, os, re
import json
from typing import Optional

from . import okf as _okf
from .html import _relpath

_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def doctor(con, now: Optional[str] = None, stale_days: Optional[int] = None) -> dict:
    """Health/maintenance report. Combines catalog validation findings with
    maintenance checks: duplicate titles; duplicate identity (same normalized
    id/alias claimed by >1 concept); hub concentration (info severity); and
    future/stale timestamps when `now` is given. Health `score` = percent of
    non-reserved concepts with zero error/warn findings (info never affects
    it). Returns: score, n_concepts, n_healthy, n_error, n_warn, n_info,
    by_rule, issues."""
    cps = con.execute(
        "SELECT path, reserved, title, timestamp, status, status_raw, stale_after, "
        "trust_tier FROM okf_concept ORDER BY path").fetchall()
    nonres = [r for r in cps if not r[1]]
    issues = [{"path": p, "severity": s, "rule": ru, "message": m}
              for p, s, ru, m in con.execute(
                  "SELECT path, severity, rule, message FROM okf_validation").fetchall()]

    # duplicate titles among non-reserved concepts
    titles = {}
    for path, _, title, *_rest in nonres:
        if title:
            titles.setdefault(title, []).append(path)
    for title, paths in titles.items():
        if len(paths) > 1:
            for p in paths:
                issues.append({"path": p, "severity": "warn", "rule": "duplicate_title",
                               "message": f"title shared with another concept: {title}"})

    # duplicate identity — same normalized id/alias claimed by >1 concept
    import json as _json
    fmres = con.execute(
        "SELECT path, frontmatter FROM okf_concept WHERE reserved = FALSE ORDER BY path").fetchall()
    normk = lambda x: "".join(ch for ch in str(x).lower() if ch.isalnum())
    claims = {}
    for path, fm_raw in fmres:
        try:
            fm = _json.loads(fm_raw or "{}")
        except Exception:
            fm = {}
        keys = []
        if fm.get("id") is not None:
            keys.append(normk(fm["id"]))
        keys += [normk(a) for a in (fm.get("aliases") or [])]
        for kk in sorted({k for k in keys if k}):
            claims.setdefault(kk, []).append(path)
    for kk in sorted(claims):
        paths = sorted(set(claims[kk]))
        if len(paths) > 1:
            for p2 in paths:
                others = ", ".join(x for x in paths if x != p2)
                issues.append({"path": p2, "severity": "warn", "rule": "duplicate_identity",
                               "message": f"id/alias '{kk}' also claimed by: {others}"})

    # hub concentration (info): outbound links mostly pointing at hub pages
    lk2 = con.execute(
        "SELECT DISTINCT src_path, dst_path FROM okf_link WHERE resolved").fetchall()
    if lk2:
        indeg = {}
        for _, d in lk2:
            indeg[d] = indeg.get(d, 0) + 1
        pos = sorted(indeg.values())
        q90 = pos[max(0, -(-9 * len(pos) // 10) - 1)]   # ceil(0.9*n), 1-based -> 0-based
        hubs = {d for d, c in indeg.items() if c >= max(3, q90)}
        outs = {}
        for s2, d in lk2:
            outs.setdefault(s2, set()).add(d)
        nonres_paths = {r[0] for r in nonres}
        for p2 in sorted(outs):
            if p2 not in nonres_paths:
                continue
            dsts = outs[p2]
            nh = len(dsts & hubs)
            if len(dsts) >= 3 and nh / len(dsts) >= 0.8:
                issues.append({"path": p2, "severity": "info", "rule": "hub_concentration",
                               "message": f"{nh}/{len(dsts)} outbound links point at hub pages"})

    # future / stale timestamps (only with a reference time)
    if now:
        try:
            now_t = datetime.datetime.strptime(now, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            now_t = None
        if now_t:
            for path, _, _, ts, *_rest in nonres:
                if not ts or not _ISO.match(ts):
                    continue
                tv = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                if tv > now_t:
                    issues.append({"path": path, "severity": "warn", "rule": "future_timestamp",
                                   "message": f"timestamp is in the future: {ts}"})
                elif stale_days is not None and (now_t - tv).days > stale_days:
                    issues.append({"path": path, "severity": "warn", "rule": "stale_timestamp",
                                   "message": f"timestamp older than {int(stale_days)} days: {ts}"})

    # ---- OKF v0.2 lifecycle, trust and attestation (SPEC 5, SPEC 10) --------
    # SPEC 11: consumers SHOULD derive trust tiers and staleness only from the
    # fields specified there. These rules are that derivation, and nothing here
    # guesses at a value the spec does not define.
    from .trust import instant as _instant, family_misshaped as _misshaped

    def _add(path, sev, rule, msg):
        issues.append({"path": path, "severity": sev, "rule": rule, "message": msg})

    # `status` outside the closed SPEC 5.4 vocabulary. Not a defect in the
    # bundle -- producer extensions legitimately reuse the key, and the R_Files
    # wiki does on 218 concepts -- but the consumer must say it is ignoring the
    # value rather than mapping it onto a lifecycle it does not mean.
    for r in nonres:
        if r[5] and not r[4]:
            _add(r[0], "info", "status_not_spec_vocabulary",
                 f"status {r[5]} is not draft/stable/deprecated (SPEC 5.4); treated as absent")

    # The same collision, generalised: a v0.2 family key carrying something
    # other than the v0.2 shape. The R_Files wiki writes `sources: 3` (a count).
    # Ignoring it is the spec-correct permissive behaviour, but silence is how a
    # consumer ends up looking like it read provenance it never saw.
    for path, fmj in con.execute(
            "SELECT path, frontmatter FROM okf_concept WHERE reserved = FALSE").fetchall():
        try:
            fm = json.loads(fmj or "{}")
        except (TypeError, ValueError):
            continue
        if not isinstance(fm, dict):
            continue
        for key in ("sources", "verified", "generated", "executor", "attester", "parameters"):
            if _misshaped(fm.get(key)):
                _add(path, "info", "family_not_spec_shape",
                     f"{key} is present but not in the SPEC 5/10 shape; treated as absent")

    # SPEC 5.5 staleness: an absolute instant, so this is a plain comparison.
    # It supersedes the age-heuristic `stale_timestamp` above, which guesses.
    if now:
        now_i = _instant(now)
        if now_i:
            for r in nonres:
                sa_i = _instant(r[6])
                if sa_i and now_i >= sa_i:
                    _add(r[0], "warn", "stale_after_passed",
                         f"stale_after {r[6]} has passed; re-verify before serving (SPEC 10.5)")

    # A live concept depending on a deprecated one. The dependency is real and
    # the target says not to use it, which is a fact only the graph can see.
    st = {r[0]: r[4] for r in nonres}
    dep = {p for p, v in st.items() if v == "deprecated"}
    if dep:
        for src, dst, kind in con.execute(
                "SELECT src_path, dst_path, kind FROM okf_link WHERE resolved").fetchall():
            if dst in dep and st.get(src) != "deprecated":
                _add(src, "warn", "deprecated_inbound",
                     f"{kind} reference to a deprecated concept: {dst}")

    # SPEC 5.1 per-claim attribution: the footnote label is the join key into
    # sources[].id. Both halves of a broken join are worth saying out loud.
    for path, sid, cited in con.execute(
            "SELECT path, id, cited FROM okf_source").fetchall():
        if sid and not cited:
            _add(path, "info", "source_id_uncited",
                 f"sources[].id {sid} is never cited by a [^{sid}] footnote")

    # SPEC 10.2/10.3 contract defects on an Attested Computation.
    for path, runtime, form, params, executor, attester in con.execute(
            "SELECT path, runtime, form, parameters, executor, attester "
            "FROM okf_computation").fetchall():
        if not runtime:
            _add(path, "warn", "computation_no_runtime",
                 "runtime is REQUIRED on an Attested Computation (SPEC 10.2)")
        if form == "none":
            _add(path, "warn", "computation_absent",
                 "neither a # Computation fence nor a computation: path (SPEC 10.3)")
        if form == "both":
            _add(path, "warn", "computation_ambiguous",
                 "both a # Computation fence and a computation: path; SPEC 10.3 allows one")
        if not attester:
            _add(path, "info", "computation_no_attester",
                 "no attester: a run of this computation cannot be checked (SPEC 10.5)")
        try:
            decl = json.loads(params or "[]")
        except (TypeError, ValueError):
            decl = []
        for prm in decl:
            if not prm.get("type"):
                _add(path, "warn", "parameter_untyped",
                     f"parameter {prm.get('name')} has no type; the typed surface is what "
                     "makes attestation mechanical (SPEC 10.3)")

    flagged = {i["path"] for i in issues if i["severity"] != "info"}  # info never hurts score
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
            "n_info": sum(1 for i in issues if i["severity"] == "info"),
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
    basename matches exactly one concept. Pages with `reviewed: true` are
    human-validated and never modified. Edits in place; returns a list of
    {path, kind, before, after}. Ambiguous cases are left for `doctor` to report."""
    b = _okf.read_bundle(root)
    lk = _okf.links(b)
    known = list(b.known)
    changes = []

    def fpath(rel):
        return os.path.join(root, rel)

    # Pages marked `reviewed: true` are human-validated — automated maintenance
    # must not touch them (protected pages).
    reviewed = {c.path for c in b.concepts if (c.frontmatter or {}).get("reviewed") is True}

    # 1) timestamp normalization (frontmatter line)
    for c in b.concepts:
        if c.reserved or not c.timestamp or c.path in reviewed:
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
        if src in reviewed:
            continue                            # protected page: report, don't edit
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
