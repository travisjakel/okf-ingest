"""okf — Open Knowledge Format ingestion (Python binding).

Mirrors the R reference binding (r/okf/R/okf.R) and writes a byte-compatible
DuckDB catalog against the same schema (schema/catalog.sql), so a bundle
ingested by either language yields the same catalog. Implements OKF v0.1
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
_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
_LINK = re.compile(r"\]\(\s*([^)\s]+)")
_SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")

# Mirror of schema/catalog.sql (that file is canonical; keep in sync).
SCHEMA = """
CREATE TABLE IF NOT EXISTS okf_bundle (bundle_id TEXT PRIMARY KEY, root TEXT,
  okf_version TEXT, source_kind TEXT, ingested_at TEXT, n_concepts INTEGER,
  n_conformant INTEGER, conformant BOOLEAN);
CREATE TABLE IF NOT EXISTS okf_concept (bundle_id TEXT, path TEXT, reserved BOOLEAN,
  type TEXT, title TEXT, description TEXT, resource TEXT, tags TEXT, timestamp TEXT,
  body TEXT, frontmatter TEXT, parse_error TEXT, content_hash TEXT,
  PRIMARY KEY (bundle_id, path));
CREATE TABLE IF NOT EXISTS okf_link (bundle_id TEXT, src_path TEXT, dst_raw TEXT,
  dst_path TEXT, resolved BOOLEAN);
CREATE TABLE IF NOT EXISTS okf_validation (bundle_id TEXT, path TEXT, severity TEXT,
  rule TEXT, message TEXT);
CREATE TABLE IF NOT EXISTS okf_chunk (bundle_id TEXT, path TEXT, chunk_id INTEGER,
  text TEXT, embedding FLOAT[]);
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
    content_hash: str


@dataclass
class Bundle:
    bundle_id: str
    root: str
    okf_version: Optional[str]
    source_kind: str
    concepts: list = field(default_factory=list)
    known: set = field(default_factory=set)


def _s(x):
    if x is None:
        return None
    if isinstance(x, (list, dict)):
        return None
    return str(x)


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


def read_bundle(root: str, bundle_id: Optional[str] = None, source_kind: str = "dir") -> Bundle:
    root = os.path.realpath(root).replace("\\", "/")
    files = []
    for dp, _, fns in os.walk(root):
        for fn in fns:
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
            tags=meta.get("tags"), timestamp=_s(meta.get("timestamp")),
            body=p["body"], frontmatter=p["meta"], parse_error=p["err"],
            links_raw=extract_links(p["body"]),
            content_hash=hashlib.sha1(p["body"].encode("utf-8")).hexdigest()))
    known = {c.path for c in concepts}
    idx = [c for c in concepts if c.path == "index.md"]
    okf_version = _s((idx[0].frontmatter or {}).get("okf_version")) if idx else None
    if bundle_id is None:
        bundle_id = hashlib.sha1(root.encode("utf-8")).hexdigest()
    return Bundle(bundle_id, root, okf_version, source_kind, concepts, known)


def links(b: Bundle) -> list:
    out = []
    for c in b.concepts:
        for raw in c.links_raw:
            if _is_external(raw):
                continue
            dst = resolve_link(raw, c.path, b.known)
            out.append({"src_path": c.path, "dst_raw": raw,
                        "dst_path": dst, "resolved": dst is not None})
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
    for lk in links(b):
        if not lk["resolved"]:
            add(lk["src_path"], "warn", "broken_link", f"unresolved link: {lk['dst_raw']}")
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
           subdir: Optional[str] = None, branch: Optional[str] = None):
    cleanup = None
    try:
        if isinstance(root, Bundle):
            b = root
        elif isinstance(root, str) and not os.path.isdir(root):
            d, kind, cleanup = fetch(root, subdir=subdir, branch=branch)
            b = read_bundle(d, bundle_id, kind)
        else:
            b = read_bundle(root, bundle_id, source_kind)
        return _ingest_bundle(b, db_path, ingested_at)
    finally:
        if cleanup:
            cleanup()


def _ingest_bundle(b, db_path, ingested_at):
    val = validate(b)
    lk = links(b)
    if ingested_at is None:
        ingested_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    err_paths = {f["path"] for f in val if f["severity"] == "error"}
    non_reserved = [c for c in b.concepts if not c.reserved]
    n_conf = sum(1 for c in non_reserved if c.path not in err_paths)

    con = duckdb.connect(db_path)
    for stmt in (s.strip() for s in SCHEMA.split(";") if s.strip()):
        con.execute(stmt)

    con.execute("INSERT INTO okf_bundle VALUES (?,?,?,?,?,?,?,?)",
                [b.bundle_id, b.root, b.okf_version, b.source_kind, ingested_at,
                 len(non_reserved), n_conf, len(err_paths) == 0])
    for c in b.concepts:
        con.execute("INSERT INTO okf_concept VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    [b.bundle_id, c.path, c.reserved, c.type, c.title, c.description,
                     c.resource, None if c.tags is None else json.dumps(c.tags),
                     c.timestamp, c.body, json.dumps(c.frontmatter or {}),
                     c.parse_error, c.content_hash])
    for lk_ in lk:
        con.execute("INSERT INTO okf_link VALUES (?,?,?,?,?)",
                    [b.bundle_id, lk_["src_path"], lk_["dst_raw"], lk_["dst_path"], lk_["resolved"]])
    for f in val:
        con.execute("INSERT INTO okf_validation VALUES (?,?,?,?,?)",
                    [b.bundle_id, f["path"], f["severity"], f["rule"], f["message"]])

    summary = {
        "n_files": len(b.concepts), "n_concepts": len(non_reserved), "n_conformant": n_conf,
        "conformant": len(err_paths) == 0,
        "errors": sum(1 for f in val if f["severity"] == "error"),
        "warnings": sum(1 for f in val if f["severity"] == "warn"),
        "links_total": len(lk), "links_broken": sum(1 for x in lk if not x["resolved"]),
    }
    return con, summary


def search(con, term: str):
    return con.execute(
        "SELECT path, type, title FROM okf_concept WHERE body ILIKE ? ORDER BY path",
        [f"%{term}%"]).fetchall()
