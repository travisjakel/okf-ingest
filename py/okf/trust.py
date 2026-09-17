"""OKF v0.2 trust, lifecycle, provenance and attested-computation semantics.

Everything here reads frontmatter families the core already preserves verbatim
and DERIVES meaning from them, which SPEC 11 asks consumers to do: "consumers
SHOULD derive trust tiers and staleness only from the fields specified here".
None of it changes ``validate()``, so the fixture-locked core stays identical
across all five bindings -- these are the R/Python surface only.

Mirrors ``r/okf/R/okf_trust.R``.
"""

import datetime as _dt
import hashlib
import json
import os
import re
from typing import Optional

from .okf import _ISO, _is_external, _is_scope, _norm, resolve_path  # noqa: F401

# SPEC 5.4: the lifecycle vocabulary is closed. A value outside it is NOT a
# lifecycle status and must not be guessed at: the R_Files wiki, for one, uses
# `status: active|settled|open|archived` (plus free prose) on 218 concepts, a
# producer extension that collides with this key. Treated as absent.
OKF_STATUS = ("draft", "stable", "deprecated")

_FOOTNOTE = re.compile(r"^\[\^([^]]+)\]:", re.M)
_COMPUTATION_H = re.compile(r"^#+[ \t]+Computation[ \t]*$")
_HEADING = re.compile(r"^#+[ \t]")
_FENCE = re.compile(r"^[ \t]*```")


def _maplist(x) -> list:
    """A v0.2 family value as a list of entry-maps, or an empty list.

    Producer extensions reuse these key names with other shapes -- the R_Files
    wiki writes ``sources: 3`` (a count) -- so every family reader checks the
    shape before indexing. A bare mapping counts as one entry (SPEC 5.2).
    """
    if x is None:
        return []
    if isinstance(x, dict):
        return [x] if any(k in x for k in ("by", "at", "resource", "name")) else []
    if isinstance(x, list):
        return [e for e in x if isinstance(e, dict)]
    return []


def family_misshaped(x) -> bool:
    """True when the key is present but carries something other than the v0.2 shape."""
    return x is not None and not _maplist(x)


def _status(fm: dict) -> Optional[str]:
    s = fm.get("status") if isinstance(fm, dict) else None
    if not isinstance(s, str):
        return None
    return s if s in OKF_STATUS else None


def instant(x) -> Optional[_dt.datetime]:
    """Parse an ISO-8601 instant with an explicit offset; None if it is not one.

    Deliberately strict: SPEC 5 says every timestamp-valued key carries an
    explicit UTC offset, and a bare local datetime has no defined instant.
    """
    if not isinstance(x, str) or not x or not _ISO.match(x):
        return None
    y = x[:-1] + "+00:00" if x.endswith("Z") else x
    if re.search(r"[+-]\d{4}$", y):
        y = y[:-2] + ":" + y[-2:]
    try:
        return _dt.datetime.fromisoformat(y)
    except ValueError:
        return None


def _latest(ats: list) -> Optional[str]:
    """SPEC 5.2: "how recently" is the latest `at`. Compare parsed INSTANTS, not
    the strings: for one instant an offset form sorts above a Z form lexically,
    so a string max can report the wrong verification as the most recent."""
    ats = [a for a in ats if isinstance(a, str) and a]
    if not ats:
        return None
    parsed = [(instant(a), a) for a in ats]
    good = [(t, a) for t, a in parsed if t is not None]
    if not good:
        return ats[-1]
    return max(good, key=lambda p: p[0])[1]


def trust(b, now: Optional[str] = None) -> list:
    """Derive the OKF v0.2 trust and lifecycle state of every concept.

    Trust tiers follow SPEC 5.3 exactly: no ``verified`` key is ``unverified``,
    ``verified`` by non-``human:`` actors only is ``machine-confirmed``, and any
    ``human:<id>`` verifier is ``human-reviewed``. Staleness follows SPEC 5.5: a
    concept is stale when ``now >= stale_after``, an absolute instant, which
    keeps the decision a plain comparison with no reference to when it was read.
    """
    ref = now or _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    now_t = instant(ref)
    out = []
    for c in b.concepts:
        fm = c.frontmatter or {}
        vs = _maplist(fm.get("verified"))
        ats = [v.get("at") for v in vs]
        bys = [v.get("by") for v in vs if isinstance(v.get("by"), str)]
        if not vs:
            tier = "unverified"
        elif any(x.startswith("human:") for x in bys):
            tier = "human-reviewed"
        else:
            tier = "machine-confirmed"
        sa = fm.get("stale_after")
        sa = sa if isinstance(sa, str) else None
        sa_t = instant(sa)
        gen = fm.get("generated")
        raw = fm.get("status")
        out.append({
            "path": c.path,
            "status": _status(fm),
            "status_raw": raw if isinstance(raw, str) else None,
            "stale_after": sa,
            "is_stale": bool(sa_t and now_t and now_t >= sa_t),
            "trust_tier": tier,
            "verified_at": _latest(ats),
            "verified_by": "; ".join(bys) if bys else None,
            "generated_by": gen.get("by") if isinstance(gen, dict) else None,
            "n_verified": len(vs),
        })
    return out


def footnote_labels(body: str) -> list:
    """Markdown footnote definition labels in a body: ``[^label]: text``."""
    return _FOOTNOTE.findall(body or "")


def sources(b) -> list:
    """Extract the ``sources`` provenance entries of a bundle (SPEC 5.1).

    One row per entry, with the per-source credibility signals kept as authored
    -- the spec records signals and refuses to store a score, so this does not
    compute one either. ``cited`` records whether the body attributes a claim to
    the entry through a footnote whose label is the entry's ``id``: the join key
    the spec defines, keyed rather than positional so that reordering the list
    cannot silently misattribute.
    """
    out = []
    for c in b.concepts:
        ss = _maplist((c.frontmatter or {}).get("sources"))
        if not ss:
            continue
        labels = footnote_labels(c.body)
        for k, s in enumerate(ss, start=1):
            sid = s.get("id")
            res = s.get("resource")
            res = res if isinstance(res, str) else None
            out.append({
                "path": c.path, "idx": k,
                "id": sid if isinstance(sid, str) else None,
                "resource": res,
                "title": s.get("title"), "author": s.get("author"),
                "usage_count": None if s.get("usage_count") is None else str(s.get("usage_count")),
                "last_modified": None if s.get("last_modified") is None else str(s.get("last_modified")),
                "is_scope": bool(res and not _is_external(res) and _is_scope(res)),
                "cited": bool(isinstance(sid, str) and sid in labels),
            })
    return out


def computation_fence(body: str) -> Optional[str]:
    """The single fenced block under a ``# Computation`` heading (SPEC 10.3).

    Returns the fence CONTENTS, or None when the heading or the fence is absent.
    """
    lines = (body or "").split("\n")
    h = [i for i, l in enumerate(lines) if _COMPUTATION_H.match(l)]
    if not h or h[0] >= len(lines) - 1:
        return None
    rest = lines[h[0] + 1:]
    nxt = [i for i, l in enumerate(rest) if _HEADING.match(l)]
    if nxt:
        rest = rest[:nxt[0]]
    op = [i for i, l in enumerate(rest) if _FENCE.match(l)]
    if len(op) < 2:
        return None
    return "\n".join(rest[op[0] + 1:op[1]])


def computations(b, now: Optional[str] = None) -> list:
    """Read the Attested Computation contracts in a bundle (SPEC 10).

    Reads and binds only -- nothing here executes or attests anything. The
    computation is either an inline fenced block under a ``# Computation``
    heading (SPEC 10.3) or a file named by the ``computation`` path field;
    declaring both, or neither, is a defect ``doctor()`` reports.
    """
    tr = {t["path"]: t for t in trust(b, now=now)}
    targets = b.files or b.known
    out = []
    for c in b.concepts:
        if c.type != "Attested Computation":
            continue
        fm = c.frontmatter or {}
        cp = fm.get("computation")
        cp = cp if isinstance(cp, str) else None
        inline = computation_fence(c.body)
        if cp and inline is not None:
            form = "both"
        elif cp:
            form = "file"
        elif inline is not None:
            form = "inline"
        else:
            form = "none"
        if form in ("file", "both"):
            p, _how = resolve_path(cp, c.path, targets)
            txt = None
            if p:
                try:
                    with open(os.path.join(b.root, p), encoding="utf-8") as fh:
                        txt = fh.read().rstrip("\n")
                except OSError:
                    txt = None
        else:
            txt = inline
        ps = _maplist(fm.get("parameters"))
        ex = fm.get("executor") if isinstance(fm.get("executor"), dict) else {}
        at = fm.get("attester") if isinstance(fm.get("attester"), dict) else {}
        t = tr.get(c.path, {})
        out.append({
            "path": c.path, "title": c.title, "runtime": fm.get("runtime"),
            "computation_path": cp, "computation": txt, "form": form,
            "n_parameters": len(ps), "parameters": json.dumps(ps),
            "executor": ex.get("resource"), "receipt": json.dumps(ex.get("receipt")),
            "attester": at.get("resource"),
            "status": t.get("status"), "stale_after": t.get("stale_after"),
            "is_stale": t.get("is_stale"), "trust_tier": t.get("trust_tier"),
        })
    return out


def canonicalize(txt: str) -> str:
    """Canonicalize a computation artifact for comparison.

    Collapses runs of whitespace, trims each line and drops blank lines, so a
    re-derived binding and a receipt's recorded artifact compare equal despite
    formatting. Deliberately conservative: it does NOT touch case, comments or
    token order, because a consumer that normalises too much stops detecting the
    rewrite it exists to detect.
    """
    lines = [re.sub(r"\s+", " ", l).strip() for l in (txt or "").split("\n")]
    return "\n".join(l for l in lines if l)


def bind(contract: dict, params: Optional[dict] = None) -> dict:
    """Bind parameter values into an Attested Computation, deterministically.

    The agent supplies *values* for the declared ``parameters`` and MUST NOT
    author or edit the computation (SPEC 10.3). Binding the computation with
    those values into the executable artifact is the consumer's job, and the
    attester independently re-derives the same binding to compare against what
    actually ran. Shipping that derivation here -- in the deterministic layer,
    with no execution -- is what lets an attester be three lines: bind,
    canonicalise, compare.

    Substitution is textual and runtime-agnostic: every occurrence of ``@name``,
    ``$name`` or ``{{name}}`` becomes the supplied value. An undeclared
    parameter name and a missing required parameter are both errors, because a
    silent partial binding is exactly the failure attestation exists to catch.
    """
    params = params or {}
    txt = contract.get("computation")
    if not txt:
        raise ValueError("contract has no computation text")
    decl = json.loads(contract.get("parameters") or "[]")
    names = [str(p.get("name")) for p in decl]
    unknown = [k for k in params if k not in names]
    if unknown:
        raise ValueError("parameter(s) not declared by the contract: " + ", ".join(unknown))
    for p in decl:
        req = p.get("required") in (True, "true")
        if req and p.get("name") not in params:
            raise ValueError("required parameter missing: " + str(p.get("name")))
    for nm in names:
        if nm not in params:
            continue
        v = str(params[nm])
        w = re.escape(nm)
        txt = re.sub(r"@" + w + r"\b", v, txt)
        txt = re.sub(r"\$" + w + r"\b", v, txt)
        txt = re.sub(r"\{\{\s*" + w + r"\s*\}\}", v, txt)
    canon = canonicalize(txt)
    return {"artifact": txt, "canonical": canon,
            "hash": hashlib.sha1(canon.encode("utf-8")).hexdigest()}
