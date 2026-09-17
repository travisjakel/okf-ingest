"""okf — Open Knowledge Format ingestion (Python binding).

Mirrors the R reference binding (r/okf/R/okf.R) and writes a byte-compatible
DuckDB catalog against the same schema (schema/catalog.sql), so a bundle
ingested by either language yields the same catalog. Implements OKF v0.2
permissive consumption: never rejects a bundle for recommended-field issues.

Public API:
    read_bundle(root)            -> Bundle (concepts + raw links)
    validate(bundle)             -> list[Finding]
    links(bundle)                -> list[Link]
    ingest(root, db_path)        -> (duckdb.Connection, summary dict)
    search(con, term)            -> rows
"""
from __future__ import annotations
import os, re, json, hashlib, datetime, tempfile, shutil, subprocess, tarfile, zipfile, urllib.request
from dataclasses import dataclass, field
from typing import Any, Optional
import yaml
import duckdb

RESERVED = {"index.md", "log.md"}


class _OKFLoader(yaml.SafeLoader):
    """SafeLoader that leaves ISO timestamps as plain strings (matching the R
    binding) instead of coercing them to datetime — keeps `timestamp` verbatim
    and frontmatter JSON-serializable."""
    pass


_OKFLoader.yaml_implicit_resolvers = {
    k: [(tag, rx) for tag, rx in v if tag != "tag:yaml.org,2002:timestamp"]
    for k, v in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
# SPEC 5: every timestamp-valued key is an ISO 8601 datetime with an explicit
# UTC offset. Upstream made this literal on 2026-08-21 and the reference bundles
# now emit "+00:00", so a trailing-Z-only pattern rejected 44 of 44 conformant
# concepts. A bare local datetime still fails: the offset is the point.
_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$")
_LINK = re.compile(r"\]\(\s*([^)\s]+)")
_WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")
_SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
_WS = re.compile(r"\s")

# Mirror of schema/catalog.sql (that file is canonical; keep in sync).
SCHEMA = """
CREATE TABLE IF NOT EXISTS okf_bundle (bundle_id TEXT PRIMARY KEY, root TEXT,
  okf_version TEXT, source_kind TEXT, ingested_at TEXT, n_concepts INTEGER,
  n_conformant INTEGER, conformant BOOLEAN);
CREATE TABLE IF NOT EXISTS okf_concept (bundle_id TEXT, path TEXT, reserved BOOLEAN,
  type TEXT, title TEXT, description TEXT, resource TEXT, tags TEXT, timestamp TEXT,
  body TEXT, frontmatter TEXT, parse_error TEXT, content_hash TEXT,
  status TEXT, status_raw TEXT, stale_after TEXT, trust_tier TEXT,
  verified_at TEXT, verified_by TEXT, generated_by TEXT,
  PRIMARY KEY (bundle_id, path));
CREATE TABLE IF NOT EXISTS okf_source (bundle_id TEXT, path TEXT, idx INTEGER,
  id TEXT, resource TEXT, title TEXT, author TEXT, usage_count TEXT,
  last_modified TEXT, is_scope BOOLEAN, cited BOOLEAN);
CREATE TABLE IF NOT EXISTS okf_computation (bundle_id TEXT, path TEXT, runtime TEXT,
  form TEXT, computation_path TEXT, computation TEXT, n_parameters INTEGER,
  parameters TEXT, executor TEXT, receipt TEXT, attester TEXT);
CREATE TABLE IF NOT EXISTS okf_link (bundle_id TEXT, src_path TEXT, dst_raw TEXT,
  dst_path TEXT, resolved BOOLEAN, kind TEXT, target TEXT);
CREATE TABLE IF NOT EXISTS okf_validation (bundle_id TEXT, path TEXT, severity TEXT,
  rule TEXT, message TEXT);
CREATE TABLE IF NOT EXISTS okf_chunk (bundle_id TEXT, path TEXT, chunk_id INTEGER,
  text TEXT, embedding FLOAT[], content_hash TEXT);
"""


@dataclass
class Concept:
    path: str
    reserved: bool
    type: Optional[str]
    title: Optional[str]
    description: Optional[str]
    resource: Optional[str]
    tags: Any
    timestamp: Optional[str]
    body: str
    frontmatter: Optional[dict]
    parse_error: Optional[str]
    links_raw: list
    wikilinks_raw: list
    content_hash: str


@dataclass
class Bundle:
    bundle_id: str
    root: str
    okf_version: Optional[str]
    source_kind: str
    concepts: list = field(default_factory=list)
    known: set = field(default_factory=set)
    # Every file in the tree, not only concepts: SPEC 6.2 path-valued fields and
    # SPEC 6.3 `references/` routinely point at non-markdown artifacts (an
    # attester .py, a computation .sql). Those are real targets, not broken links.
    files: set = field(default_factory=set)


def _s(x):
    if x is None:
        return None
    if isinstance(x, (list, dict)):
        return None
    return str(x)


def _ts(meta: dict):
    """Concept freshness: `timestamp`, falling back to OKF v0.2
    `generated: {by, at}` (spec section 13 fallback)."""
    if meta.get("timestamp") is not None:
        return meta["timestamp"]
    g = meta.get("generated")
    return g.get("at") if isinstance(g, dict) else None


def parse_file(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        # splitlines() (not split("\n")) matches R's readLines(): it strips the
        # EOL — including a trailing newline and CR in CRLF — so the body and
        # its content_hash are identical across the two bindings.
        raw = fh.read().splitlines()
    txt = "\n".join(raw)
    i = 0
    while i < len(raw) and raw[i].strip() == "":
        i += 1
    if i >= len(raw) or not re.match(r"^---\s*$", raw[i]):
        return {"meta": None, "body": txt, "err": "no_frontmatter"}
    fences = [j for j, ln in enumerate(raw) if re.match(r"^---\s*$", ln)]
    opn = next(f for f in fences if f >= i)
    after = [f for f in fences if f > opn]
    if not after:
        return {"meta": None, "body": txt, "err": "unclosed_frontmatter"}
    close = after[0]
    fm = "\n".join(raw[opn + 1:close])
    body = "\n".join(raw[close + 1:]) if close < len(raw) - 1 else ""
    try:
        meta = yaml.load(fm, Loader=_OKFLoader)
    except Exception:
        meta = None
    if meta is None or not isinstance(meta, dict):
        return {"meta": None, "body": body, "err": "yaml_parse_error"}
    return {"meta": meta, "body": body, "err": None}


def extract_links(body: str) -> list:
    return _LINK.findall(body)


def extract_wikilinks(body: str) -> list:
    """Extract [[wikilink]] / [[target|display]] references (display + #anchor
    stripped). Resolved by name (id/alias/title/stem), not path — see links()."""
    return [m.split("|", 1)[0].strip() for m in _WIKILINK.findall(body)]


def _wiki_index(concepts: list) -> dict:
    """lowercased id/alias/title/stem -> path. Keys mapping to >1 concept are
    ambiguous and dropped (a wikilink to an ambiguous name resolves to nothing,
    deterministically). id/alias/title precedence is applied at resolution."""
    maps = {"id": {}, "alias": {}, "title": {}, "stem": {}}
    amb = {"id": set(), "alias": set(), "title": set(), "stem": set()}

    def add(kind, key, path):
        key = str(key).strip().lower()
        if not key:
            return
        if maps[kind].get(key, path) != path:
            amb[kind].add(key)
        maps[kind][key] = path
    for c in concepts:
        fm = c.frontmatter or {}
        if fm.get("id") is not None:
            add("id", fm["id"], c.path)
        if c.title:
            add("title", c.title, c.path)
        for a in (fm.get("aliases") or []):
            add("alias", a, c.path)
        add("stem", os.path.splitext(os.path.basename(c.path))[0], c.path)
    for kind in maps:
        for k in amb[kind]:
            maps[kind].pop(k, None)
    return maps


def resolve_wiki(ref: str, idx: dict, known: set) -> Optional[str]:
    ref = ref.split("#", 1)[0].strip()
    if not ref:
        return None
    if ref in known:
        return ref
    cand = ref if ref.endswith(".md") else ref + ".md"
    if cand in known:
        return cand
    lref = ref.lower()
    for kind in ("id", "alias", "title", "stem"):
        v = idx[kind].get(lref)
        if v is not None:
            return v
    return None


def _norm(p: str) -> str:
    out = []
    for s in p.replace("\\", "/").split("/"):
        if s in ("", "."):
            continue
        if s == "..":
            if out:
                out.pop()
            continue
        out.append(s)
    return "/".join(out)


def _is_external(raw: str) -> bool:
    return bool(_SCHEME.match(raw.split("#", 1)[0]))


def resolve_link(raw: str, src_rel: str, known: set) -> Optional[str]:
    t = raw.split("#", 1)[0]
    if t.startswith("/"):
        cand = t[1:]
    else:
        d = os.path.dirname(src_rel)
        cand = t if d == "" else f"{d}/{t}"
    cand = _norm(cand)
    return cand if cand in known else None


def fm_paths(fm: Optional[dict]) -> list:
    """Path-valued frontmatter fields (SPEC 6.2): `resource`, `sources[].resource`,
    `computation`, `executor.resource`, `attester.resource`. Fixed order, so the
    edge list stays deterministic."""
    if not fm:
        return []
    out = []

    def push(kind, v):
        if v is None:
            return
        if isinstance(v, (list, tuple)):
            v = v[0] if v else None
        if v is None:
            return
        v = str(v)
        if v:
            out.append({"kind": kind, "raw": v})

    push("resource", fm.get("resource"))
    push("computation", fm.get("computation"))
    ex = fm.get("executor")
    if isinstance(ex, dict):
        push("executor", ex.get("resource"))
    at = fm.get("attester")
    if isinstance(at, dict):
        push("attester", at.get("resource"))
    ss = fm.get("sources")
    if isinstance(ss, dict):
        ss = [ss]
    if isinstance(ss, list):
        for src in ss:
            if isinstance(src, dict):
                push("source", src.get("resource"))
    return out


def _is_scope(raw: str) -> bool:
    """A `sources[].resource` MAY be a scope descriptor rather than a path
    (SPEC 5.1), e.g. "all queries in BigQuery project X". A path never contains
    whitespace, which is the only signal the spec gives."""
    return bool(_WS.search(raw))


def resolve_path(raw: str, src_rel: str, targets) -> tuple:
    """Resolve a path-valued frontmatter field. Applies the SPEC 6.2 reading
    first (a leading "/" is bundle-relative, otherwise relative to the concept's
    own directory); if that finds nothing, falls back to the bundle root. The
    fallback exists because the reference bundles write root-relative paths
    WITHOUT the leading slash -- all 12 frontmatter paths in upstream's
    acme_retail resolve that way and none resolve the spec-literal way -- and a
    consumer is required to be permissive (SPEC 11).

    Returns (path_or_None, how) where how is "spec", "root" or None."""
    t = raw.split("#", 1)[0]
    if t.startswith("/"):
        spec = _norm(t[1:])
    else:
        d = os.path.dirname(src_rel)
        spec = _norm(t if d == "" else f"{d}/{t}")
    if spec in targets:
        return spec, "spec"
    root = _norm(t[1:] if t.startswith("/") else t)
    if root in targets:
        return root, "root"
    return None, None


def read_bundle(root: str, bundle_id: Optional[str] = None, source_kind: str = "dir") -> Bundle:
    root = os.path.realpath(root).replace("\\", "/")
    files = []
    all_files = set()
    for dp, dns, fns in os.walk(root):
        # skip hidden directories (.git/.github/.githooks/…) — tooling, not
        # concepts — to match R's list.files() default (parity).
        dns[:] = [d for d in dns if not d.startswith(".")]
        for fn in fns:
            if fn.startswith("."):
                continue
            all_files.add(os.path.relpath(os.path.join(dp, fn), root).replace('\\', '/'))
            if fn.endswith(".md"):
                files.append(os.path.join(dp, fn))
    files.sort()
    concepts = []
    for f in files:
        rel = os.path.relpath(f, root).replace("\\", "/")
        p = parse_file(f)
        meta = p["meta"] or {}
        concepts.append(Concept(
            path=rel, reserved=os.path.basename(f) in RESERVED,
            type=_s(meta.get("type")), title=_s(meta.get("title")),
            description=_s(meta.get("description")), resource=_s(meta.get("resource")),
            tags=meta.get("tags"), timestamp=_s(_ts(meta)),
            body=p["body"], frontmatter=p["meta"], parse_error=p["err"],
            links_raw=extract_links(p["body"]),
            wikilinks_raw=extract_wikilinks(p["body"]),
            content_hash=hashlib.sha1(p["body"].encode("utf-8")).hexdigest()))
    known = {c.path for c in concepts}
    idx = [c for c in concepts if c.path == "index.md"]
    okf_version = _s((idx[0].frontmatter or {}).get("okf_version")) if idx else None
    if bundle_id is None:
        bundle_id = hashlib.sha1(root.encode("utf-8")).hexdigest()
    return Bundle(bundle_id, root, okf_version, source_kind, concepts, known, all_files)


def links(b: Bundle) -> list:
    """Three edge sources, in this order: markdown links, [[wikilink]] references,
    and the path-valued frontmatter fields of SPEC 6.2. The last group carries the
    derivation and execution edges, which appear nowhere in the body: on upstream
    acme_retail they are 12 edges against 30 body edges, and without them "what
    depends on this policy" is answerable only from the directory index.

    `target` says what the reference points at: "concept" (the only case that
    forms a graph edge), "file" (a real non-concept file in the bundle, such as
    an attester .py -- present, so not broken), "scope" (a SPEC 5.1 scope
    descriptor, not a path at all), or "missing"."""
    out = []
    idx = _wiki_index(b.concepts)
    targets = b.files or b.known
    for c in b.concepts:
        for raw in c.links_raw:
            if _is_external(raw):
                continue
            dst = resolve_link(raw, c.path, b.known)
            if dst is not None:
                tgt = "concept"
            else:
                tgt = "file" if resolve_path(raw, c.path, targets)[0] else "missing"
            out.append({"src_path": c.path, "dst_raw": raw, "dst_path": dst,
                        "resolved": dst is not None, "kind": "body", "target": tgt})
        for raw in c.wikilinks_raw:
            dst = resolve_wiki(raw, idx, b.known)
            out.append({"src_path": c.path, "dst_raw": raw, "dst_path": dst,
                        "resolved": dst is not None, "kind": "wikilink",
                        "target": "concept" if dst is not None else "missing"})
    # Frontmatter edges are appended last, so body-link ordering is untouched.
    for c in b.concepts:
        for fp in fm_paths(c.frontmatter):
            raw, kind = fp["raw"], fp["kind"]
            if _is_external(raw):
                continue
            if kind == "source" and _is_scope(raw):
                out.append({"src_path": c.path, "dst_raw": raw, "dst_path": None,
                            "resolved": False, "kind": kind, "target": "scope"})
                continue
            path, _how = resolve_path(raw, c.path, targets)
            if path is None:
                out.append({"src_path": c.path, "dst_raw": raw, "dst_path": None,
                            "resolved": False, "kind": kind, "target": "missing"})
                continue
            is_concept = path in b.known
            out.append({"src_path": c.path, "dst_raw": raw,
                        "dst_path": path if is_concept else None,
                        "resolved": is_concept, "kind": kind,
                        "target": "concept" if is_concept else "file"})
    return out


def validate(b: Bundle) -> list:
    out = []
    def add(path, sev, rule, msg):
        out.append({"path": path, "severity": sev, "rule": rule, "message": msg})
    for c in b.concepts:
        if c.reserved:
            continue
        if c.parse_error is not None:
            add(c.path, "error", "frontmatter_unparseable",
                f"no parseable frontmatter ({c.parse_error})")
            continue
        if not c.type:
            add(c.path, "error", "missing_type", "frontmatter has no non-empty type")
        if c.title is None:
            add(c.path, "warn", "missing_title", "recommended field title absent")
        if c.description is None:
            add(c.path, "warn", "missing_description", "recommended field description absent")
        if c.timestamp is None:
            add(c.path, "warn", "missing_timestamp", "recommended field timestamp absent")
        elif not _ISO.match(c.timestamp):
            add(c.path, "warn", "timestamp_not_iso8601", f"timestamp not ISO-8601: {c.timestamp}")
    lk_all = links(b)
    for lk in lk_all:
        if lk["target"] in ("concept", "scope"):
            continue
        raw = lk["dst_raw"]
        if lk["target"] == "file":
            # The target exists, it is simply not a concept (an attester .py, a
            # computation .sql). SPEC 6.2 and 6.3 expect exactly this; not a defect.
            add(lk["src_path"], "info", "non_concept_target",
                f"reference resolves to a non-concept file: {raw}")
        elif lk["kind"] in ("body", "wikilink"):
            add(lk["src_path"], "warn", "broken_link", f"unresolved link: {raw}")
        else:
            add(lk["src_path"], "warn", "broken_reference",
                f"unresolved {lk['kind']} path: {raw}")
    # A frontmatter path that resolves only against the bundle root, though SPEC
    # 6.2 reserves that meaning for a leading slash. Reported so a producer can
    # fix it; consumed regardless, because a consumer must be permissive (SPEC 11).
    _targets = b.files or b.known
    for c in b.concepts:
        for fp in fm_paths(c.frontmatter):
            raw, kind = fp["raw"], fp["kind"]
            if _is_external(raw) or (kind == "source" and _is_scope(raw)):
                continue
            if raw.startswith("/"):
                continue
            if resolve_path(raw, c.path, _targets)[1] == "root":
                add(c.path, "info", "path_root_relative",
                    f"{kind} path resolves against the bundle root, not the concept "
                    f"directory; SPEC 6.2 reserves that for a leading slash: {raw}")
    # orphan concepts (Karpathy-style lint): non-reserved, parseable, no inbound link
    inbound = {lk["dst_path"] for lk in lk_all if lk["resolved"]}
    for c in b.concepts:
        if c.reserved or c.parse_error is not None:
            continue
        if c.path not in inbound:
            add(c.path, "warn", "orphan", "no inbound links (orphan concept)")
    return out


def _source_kind(source: str) -> str:
    s = re.sub(r"[?#].*$", "", source)
    if re.search(r"\.zip$", s, re.I):
        return "zip"
    if re.search(r"\.(tar\.gz|tgz|tar|tar\.bz2)$", s, re.I):
        return "tar"
    if s.endswith(".git") or source.startswith("git@") or \
       re.match(r"^https?://(www\.)?(github|gitlab|bitbucket)\.", s):
        return "git"
    raise ValueError(f"cannot determine source kind (expected a dir, git URL, or tar/zip): {source}")


def _assert_safe_members(base: str, names) -> None:
    """Reject archive members that would extract outside `base` (path traversal
    / zip-slip), before extracting anything."""
    base_r = os.path.realpath(base)
    for n in names:
        target = os.path.realpath(os.path.join(base, n))
        if target != base_r and not target.startswith(base_r + os.sep):
            raise RuntimeError(f"archive member escapes target dir (path traversal): {n!r}")


def _bundle_root(base: str, subdir: Optional[str]) -> str:
    if subdir:
        return os.path.join(base, subdir)
    cur = base
    for _ in range(6):
        entries = [e for e in os.listdir(cur) if not e.startswith(".")]
        has_md = any(e.lower().endswith(".md") for e in entries)
        dirs = [e for e in entries if os.path.isdir(os.path.join(cur, e))]
        if not has_md and len(dirs) == 1:
            cur = os.path.join(cur, dirs[0])
        else:
            break
    return cur


def fetch(source: str, subdir: Optional[str] = None, branch: Optional[str] = None):
    """Materialize a bundle from a dir, git URL, or tar/zip (local or remote).
    Returns (dir, source_kind, cleanup); the caller must call cleanup()."""
    if os.path.isdir(source):
        return os.path.realpath(source), "dir", (lambda: None)
    kind = _source_kind(source)
    tmp = tempfile.mkdtemp(prefix="okf_")

    def cleanup():
        shutil.rmtree(tmp, ignore_errors=True)
    try:
        if kind == "git":
            args = ["git", "clone", "--depth", "1"]
            if branch:
                args += ["--branch", branch]
            args += [source, os.path.join(tmp, "repo")]
            if subprocess.run(args, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode != 0:
                raise RuntimeError(f"git clone failed (is git installed?): {source}")
            base = os.path.join(tmp, "repo")
        else:
            local = source
            if re.match(r"^https?://", source):
                local = os.path.join(tmp, os.path.basename(re.sub(r"[?#].*$", "", source)))
                urllib.request.urlretrieve(source, local)
            ex = os.path.join(tmp, "x"); os.makedirs(ex)
            if kind == "zip":
                with zipfile.ZipFile(local) as z:
                    _assert_safe_members(ex, z.namelist())
                    z.extractall(ex)
            else:
                with tarfile.open(local) as t:
                    try:
                        t.extractall(ex, filter="data")   # py>=3.12 sanitizes
                    except TypeError:                      # older Python: guard manually
                        _assert_safe_members(ex, [m.name for m in t.getmembers()])
                        t.extractall(ex)
            base = ex
    except Exception:
        cleanup()
        raise
    return _bundle_root(base, subdir), kind, cleanup


def ingest(root, db_path: str = ":memory:", ingested_at: Optional[str] = None,
           bundle_id: Optional[str] = None, source_kind: str = "dir",
           subdir: Optional[str] = None, branch: Optional[str] = None,
           incremental: bool = False):
    cleanup = None
    try:
        if isinstance(root, Bundle):
            b = root
        elif isinstance(root, str) and not os.path.isdir(root):
            d, kind, cleanup = fetch(root, subdir=subdir, branch=branch)
            b = read_bundle(d, bundle_id, kind)
        else:
            b = read_bundle(root, bundle_id, source_kind)
        return _ingest_bundle(b, db_path, ingested_at, incremental)
    finally:
        if cleanup:
            cleanup()


def _concept_row(b, c, tr=None):
    t = (tr or {}).get(c.path, {})
    return [b.bundle_id, c.path, c.reserved, c.type, c.title, c.description,
            c.resource, None if c.tags is None else json.dumps(c.tags),
            c.timestamp, c.body, json.dumps(c.frontmatter or {}),
            c.parse_error, c.content_hash,
            t.get("status"), t.get("status_raw"), t.get("stale_after"),
            t.get("trust_tier"), t.get("verified_at"), t.get("verified_by"),
            t.get("generated_by")]


def _ingest_bundle(b, db_path, ingested_at, incremental=False):
    val = validate(b)
    lk = links(b)
    if ingested_at is None:
        ingested_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    err_paths = {f["path"] for f in val if f["severity"] == "error"}
    non_reserved = [c for c in b.concepts if not c.reserved]
    n_conf = sum(1 for c in non_reserved if c.path not in err_paths)
    bid = b.bundle_id

    con = duckdb.connect(db_path)
    for stmt in (s.strip() for s in SCHEMA.split(";") if s.strip()):
        con.execute(stmt)

    # SPEC 5 trust / lifecycle, derived once and carried as columns so a catalog
    # query (and doctor) can reason about it without re-parsing frontmatter.
    from .trust import trust as _trust, sources as _sources, computations as _computations
    tr = {t["path"]: t for t in _trust(b, now=ingested_at)}

    prior = dict(con.execute(
        "SELECT path, content_hash FROM okf_concept WHERE bundle_id = ?", [bid]).fetchall())
    incr = bool(incremental) and len(prior) > 0
    inc_stats = {}

    if incr:
        cur = {c.path: c.content_hash for c in b.concepts}
        changed = [p for p in cur if p in prior and cur[p] != prior[p]]
        added = [p for p in cur if p not in prior]
        removed = [p for p in prior if p not in cur]
        drop = changed + removed
        if drop:
            con.execute("DELETE FROM okf_concept WHERE bundle_id = ? AND path IN ({})".format(
                ",".join("?" * len(drop))), [bid] + drop)
        for c in b.concepts:
            if c.path in changed or c.path in added:
                con.execute("INSERT INTO okf_concept VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", _concept_row(b, c, tr))
        kept = len(set(cur) & set(prior))
        inc_stats = {"changed": len(changed), "added": len(added),
                     "removed": len(removed), "cached": kept - len(changed)}
    else:
        for t in ("okf_bundle", "okf_concept", "okf_link", "okf_validation",
                  "okf_source", "okf_computation"):
            con.execute(f"DELETE FROM {t} WHERE bundle_id = ?", [bid])
        for c in b.concepts:
            con.execute("INSERT INTO okf_concept VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", _concept_row(b, c, tr))

    # Bundle row + graph-global tables: always rewritten to current state.
    con.execute("DELETE FROM okf_bundle WHERE bundle_id = ?", [bid])
    con.execute("INSERT INTO okf_bundle VALUES (?,?,?,?,?,?,?,?)",
                [bid, b.root, b.okf_version, b.source_kind, ingested_at,
                 len(non_reserved), n_conf, len(err_paths) == 0])
    con.execute("DELETE FROM okf_link WHERE bundle_id = ?", [bid])
    con.execute("DELETE FROM okf_validation WHERE bundle_id = ?", [bid])
    for lk_ in lk:
        con.execute("INSERT INTO okf_link VALUES (?,?,?,?,?,?,?)",
                    [bid, lk_["src_path"], lk_["dst_raw"], lk_["dst_path"],
                     lk_["resolved"], lk_["kind"], lk_["target"]])
    for f in val:
        con.execute("INSERT INTO okf_validation VALUES (?,?,?,?,?)",
                    [bid, f["path"], f["severity"], f["rule"], f["message"]])
    con.execute("DELETE FROM okf_source WHERE bundle_id = ?", [bid])
    con.execute("DELETE FROM okf_computation WHERE bundle_id = ?", [bid])
    for sr in _sources(b):
        con.execute("INSERT INTO okf_source VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    [bid, sr["path"], sr["idx"], sr["id"], sr["resource"], sr["title"],
                     sr["author"], sr["usage_count"], sr["last_modified"],
                     sr["is_scope"], sr["cited"]])
    for cm in _computations(b, now=ingested_at):
        con.execute("INSERT INTO okf_computation VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    [bid, cm["path"], cm["runtime"], cm["form"], cm["computation_path"],
                     cm["computation"], cm["n_parameters"], cm["parameters"],
                     cm["executor"], cm["receipt"], cm["attester"]])

    summary = {
        "n_files": len(b.concepts), "n_concepts": len(non_reserved), "n_conformant": n_conf,
        "conformant": len(err_paths) == 0,
        "errors": sum(1 for f in val if f["severity"] == "error"),
        "warnings": sum(1 for f in val if f["severity"] == "warn"),
        "links_total": len(lk),
        "links_broken": sum(1 for x in lk if x["target"] == "missing"),
        **inc_stats,
    }
    return con, summary


def search(con, term: str):
    return con.execute(
        "SELECT path, type, title FROM okf_concept WHERE body ILIKE ? ORDER BY path",
        [f"%{term}%"]).fetchall()


def _bfs_select(cps, adj, nonres, start, depth):
    sel, seen, frontier, dd = [start], {start}, [start], 0
    while dd < depth and frontier:
        nxt = []
        for p in frontier:
            for nb in adj.get(p, ()):  # noqa: B007
                if nb not in seen:
                    seen.add(nb)
                    nxt.append(nb)
        sel += nxt
        frontier = nxt
        dd += 1
    return [p for p in sel if p in nonres]


def context(con, start=None, depth: int = 1, max_tokens: int = 8000, include_index: bool = True, rank: str = "bfs", query=None):
    """Assemble an index-first, link-following slice of a bundle as one markdown
    blob for direct LLM consumption — the OKF / "LLM wiki" consume primitive.
    Uses the concept graph (no embeddings, no vector search). With `start`, walks
    the undirected link graph to `depth`; otherwise packs all concepts. Output is
    capped to ~`max_tokens` (~4 chars/token). Returns a dict with text/included/
    omitted/est_tokens."""
    cps = {p: {"reserved": r, "title": t, "body": b} for p, r, t, b in con.execute(
        "SELECT path, reserved, title, body FROM okf_concept").fetchall()}
    adj = {}
    for s, d in con.execute("SELECT src_path, dst_path FROM okf_link WHERE resolved").fetchall():
        adj.setdefault(s, set()).add(d)
        adj.setdefault(d, set()).add(s)
    nonres = [p for p, v in cps.items() if not v["reserved"]]

    seeds_used = None
    if query is not None and start is not None:
        raise ValueError("give either start or query, not both")
    if query is not None:
        from .graph import ppr as _ppr, seeds as _seeds
        seeds_used = _seeds(con, query)
        if not seeds_used:
            raise ValueError(f"query matched no concepts: {query}")
        r = _ppr(con, [x["path"] for x in seeds_used],
                 weights=[x["score"] for x in seeds_used], k=None)
        sel = [x["path"] for x in r if x["path"] in nonres]
    elif start is not None:
        if start not in cps:
            raise ValueError(f"start concept not found: {start}")
        if rank == "ppr":
            from .graph import ppr as _ppr
            sel = [r["path"] for r in _ppr(con, start, k=None) if r["path"] in nonres]
        else:
            sel = _bfs_select(cps, adj, nonres, start, depth)
    else:
        sel = sorted(nonres)

    est = lambda s: -(-len(s) // 4)
    row = con.execute("SELECT root FROM okf_bundle LIMIT 1").fetchone()
    root = os.path.basename(row[0]) if row and row[0] else "bundle"
    out = [f"# OKF context -- {root}\n"]
    used = est(out[0]); inc = []; omit = []

    def add(label, body):
        nonlocal used
        s = f"\n## {label}\n\n{body or ''}\n"
        if used + est(s) <= max_tokens:
            out.append(s); used += est(s); return True
        return False

    if include_index and "index.md" in cps:
        add("index.md", cps["index.md"]["body"])
    for p in sel:
        v = cps[p]
        label = f'{v["title"]} ({p})' if v["title"] else p
        (inc if add(label, v["body"]) else omit).append(p)
    res = {"text": "".join(out), "included": inc, "omitted": omit, "est_tokens": used}
    if seeds_used is not None:
        res["seeds"] = [x["path"] for x in seeds_used]
    return res
