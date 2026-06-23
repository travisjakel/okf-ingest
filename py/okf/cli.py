#!/usr/bin/env python3
"""okf — command-line interface (Python). Mirrors r/okf/bin/okf.R.

  okf validate <bundle> [--strict] [--json]
  okf ingest   <bundle> --db <path> [--id <id>] [--json]
  okf query    <db> [--sql "..."] [--search <term>] [--concepts] [--links] [--findings] [--json]
  okf html     <bundle|db> --out <dir> | --single <file.html> [--title T]
  okf graph    <bundle|db> --out <file.html> [--title T]
  okf export   <bundle|db> [--json]                 # portable {nodes, edges} graph JSON
  okf impact   <bundle|db> <concept> [--json]       # inbound / outbound / transitive
  okf doctor   <bundle|db> [--strict] [--stale-days N] [--fix] [--json]  # health / maintenance

Exit codes: 0 ok · 1 conformance failure · 2 usage error.
"""
import argparse, json, os, sys

# allow running as `python py/okf/cli.py ...` (put the package parent on path)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import okf.okf as okf  # noqa: E402
from okf.rag import embed as rag_embed, rag as rag_search, ollama_embedder  # noqa: E402

import duckdb  # noqa: E402


def _print(rows, cols, as_json):
    if as_json:
        print(json.dumps([dict(zip(cols, r)) for r in rows], indent=2, default=str))
    else:
        print(" | ".join(cols))
        for r in rows:
            print(" | ".join("" if v is None else str(v) for v in r))


def main(argv=None):
    p = argparse.ArgumentParser(prog="okf", add_help=True)
    sub = p.add_subparsers(dest="cmd")

    v = sub.add_parser("validate"); v.add_argument("bundle")
    v.add_argument("--strict", action="store_true"); v.add_argument("--json", action="store_true")

    i = sub.add_parser("ingest"); i.add_argument("bundle")
    i.add_argument("--db", default=":memory:"); i.add_argument("--id", default=None)
    i.add_argument("--subdir", default=None); i.add_argument("--branch", default=None)
    i.add_argument("--incremental", action="store_true"); i.add_argument("--json", action="store_true")

    q = sub.add_parser("query"); q.add_argument("db")
    q.add_argument("--sql"); q.add_argument("--search")
    q.add_argument("--concepts", action="store_true"); q.add_argument("--links", action="store_true")
    q.add_argument("--findings", action="store_true"); q.add_argument("--json", action="store_true")

    c = sub.add_parser("context"); c.add_argument("source")
    c.add_argument("--start"); c.add_argument("--depth", type=int, default=1)
    c.add_argument("--max-tokens", type=int, default=8000, dest="max_tokens")
    c.add_argument("--no-index", action="store_true")
    c.add_argument("--subdir"); c.add_argument("--branch")

    h = sub.add_parser("html"); h.add_argument("source")
    h.add_argument("--out"); h.add_argument("--single")
    h.add_argument("--title"); h.add_argument("--subdir"); h.add_argument("--branch")
    h.add_argument("--json", action="store_true")

    gr = sub.add_parser("graph"); gr.add_argument("source")
    gr.add_argument("--out"); gr.add_argument("--title")
    gr.add_argument("--subdir"); gr.add_argument("--branch")

    ex = sub.add_parser("export"); ex.add_argument("source")
    ex.add_argument("--subdir"); ex.add_argument("--branch")
    ex.add_argument("--json", action="store_true"); ex.add_argument("--mermaid", action="store_true")

    im = sub.add_parser("impact"); im.add_argument("source"); im.add_argument("concept")
    im.add_argument("--subdir"); im.add_argument("--branch"); im.add_argument("--json", action="store_true")

    dr = sub.add_parser("doctor"); dr.add_argument("source")
    dr.add_argument("--strict", action="store_true"); dr.add_argument("--fix", action="store_true")
    dr.add_argument("--stale-days", type=int, default=None, dest="stale_days")
    dr.add_argument("--subdir"); dr.add_argument("--branch"); dr.add_argument("--json", action="store_true")

    e = sub.add_parser("embed"); e.add_argument("db")
    e.add_argument("--model", default="nomic-embed-text")
    e.add_argument("--incremental", action="store_true"); e.add_argument("--json", action="store_true")

    r = sub.add_parser("rag"); r.add_argument("db"); r.add_argument("--query", required=True)
    r.add_argument("-k", type=int, default=5); r.add_argument("--model", default="nomic-embed-text")
    r.add_argument("--json", action="store_true")

    a = p.parse_args(argv)
    if not a.cmd:
        p.print_help(); return 2

    if a.cmd == "validate":
        b = okf.read_bundle(a.bundle)
        val = okf.validate(b)
        nerr = sum(1 for f in val if f["severity"] == "error")
        nwarn = sum(1 for f in val if f["severity"] == "warn")
        conf = nerr == 0
        if a.json:
            print(json.dumps({"bundle": a.bundle, "conformant": conf, "errors": nerr,
                              "warnings": nwarn, "findings": val}, indent=2))
        else:
            print(f"bundle: {a.bundle}\nconformant: {conf}  (errors: {nerr}, warnings: {nwarn})")
            for f in val:
                print(f"  [{f['severity']:<5}] {f['rule']:<22} {f['path']} — {f['message']}")
        return 1 if (not conf or (a.strict and nwarn > 0)) else 0

    def _open(source, subdir, branch):
        if source.endswith(".duckdb") and os.path.isfile(source):
            return duckdb.connect(source, read_only=True)
        con, _ = okf.ingest(source, subdir=subdir, branch=branch)
        return con

    if a.cmd == "ingest":
        con, s = okf.ingest(a.bundle, db_path=a.db, bundle_id=a.id,
                            subdir=a.subdir, branch=a.branch, incremental=a.incremental)
        con.close()
        if a.json:
            print(json.dumps({"bundle": a.bundle, "db": a.db, **s}, indent=2))
        else:
            print(f"ingested {a.bundle} -> {a.db}\n  concepts={s['n_concepts']} "
                  f"conformant={s['n_conformant']} ({s['conformant']}) errors={s['errors']} "
                  f"warnings={s['warnings']} links={s['links_total']} broken={s['links_broken']}")
            if "changed" in s:
                print(f"  incremental: changed={s['changed']} added={s['added']} "
                      f"removed={s['removed']} cached={s['cached']}")
        return 0 if s["conformant"] else 1

    if a.cmd == "query":
        con = duckdb.connect(a.db, read_only=True)
        try:
            if a.sql:
                cur = con.execute(a.sql)
            elif a.search:
                cur = con.execute("SELECT path,type,title FROM okf_concept WHERE body ILIKE ? ORDER BY path",
                                  [f"%{a.search}%"])
            elif a.links:
                cur = con.execute("SELECT * FROM okf_link")
            elif a.findings:
                cur = con.execute("SELECT * FROM okf_validation ORDER BY severity, path")
            else:
                cur = con.execute("SELECT path,reserved,type,title FROM okf_concept ORDER BY path")
            cols = [d[0] for d in cur.description]
            _print(cur.fetchall(), cols, a.json)
        finally:
            con.close()
        return 0

    if a.cmd == "context":
        # source may be a .duckdb catalog or a bundle (dir/git/tar/zip)
        if a.source.endswith(".duckdb") and os.path.isfile(a.source):
            con = duckdb.connect(a.source, read_only=True); close = con.close
        else:
            con, _ = okf.ingest(a.source, subdir=a.subdir, branch=a.branch); close = con.close
        try:
            ctx = okf.context(con, start=a.start, depth=a.depth,
                              max_tokens=a.max_tokens, include_index=not a.no_index)
        finally:
            close()
        sys.stdout.write(ctx["text"])
        sys.stderr.write(f"\n<!-- okf context: {len(ctx['included'])} concepts, "
                         f"~{ctx['est_tokens']} tokens, {len(ctx['omitted'])} omitted -->\n")
        return 0

    if a.cmd == "html":
        from okf.html import render_html
        if a.source.endswith(".duckdb") and os.path.isfile(a.source):
            con = duckdb.connect(a.source, read_only=True)
        else:
            con, _ = okf.ingest(a.source, subdir=a.subdir, branch=a.branch)
        single = a.single is not None
        out = a.single if single else a.out
        if not out:
            print("html: need --out <dir> or --single <file.html>"); con.close(); return 2
        try:
            r = render_html(con, out, single=single, site_title=a.title)
        finally:
            con.close()
        if a.json:
            print(json.dumps(r, indent=2))
        return 0

    if a.cmd == "graph":
        from okf.graph import graph_html
        if not a.out:
            print("graph: need --out <file.html>"); return 2
        con = _open(a.source, a.subdir, a.branch)
        try:
            graph_html(con, a.out, site_title=a.title)
        finally:
            con.close()
        return 0

    if a.cmd == "export":
        from okf.graph import graph_json, graph_mermaid
        con = _open(a.source, a.subdir, a.branch)
        try:
            sys.stdout.write((graph_mermaid(con) if a.mermaid else graph_json(con)) + "\n")
        finally:
            con.close()
        return 0

    if a.cmd == "impact":
        from okf.graph import impact
        con = _open(a.source, a.subdir, a.branch)
        try:
            im = impact(con, a.concept)
        finally:
            con.close()
        if a.json:
            print(json.dumps(im, indent=2))
        else:
            print(f"impact of {a.concept}")
            for k in ("outbound", "inbound", "transitive"):
                print(f"  {k} ({len(im[k])}): {', '.join(im[k])}")
        return 0

    if a.cmd == "doctor":
        from okf.doctor import doctor, doctor_fix
        import datetime as _dt
        is_db = a.source.endswith(".duckdb") and os.path.isfile(a.source)
        if a.fix:
            if is_db:
                print("doctor --fix needs a bundle directory (not a .duckdb catalog)"); return 2
            ch = doctor_fix(a.source)
            for c in ch:
                print(f"  fixed [{c['kind']}] {c['path']}: {c['before']} -> {c['after']}")
            if not ch:
                print("  no safely-fixable issues")
        con = _open(a.source, a.subdir, a.branch)
        try:
            now = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if a.stale_days else None
            rep = doctor(con, now=now, stale_days=a.stale_days)
        finally:
            con.close()
        if a.json:
            print(json.dumps(rep, indent=2))
        else:
            print(f"health: {rep['score']}/100  ({rep['n_healthy']}/{rep['n_concepts']} concepts clean "
                  f"· {rep['n_error']} errors · {rep['n_warn']} warnings)")
            for r, c in sorted(rep["by_rule"].items()):
                print(f"  {r:<22} {c}")
        return 0 if (rep["n_error"] == 0 and not (a.strict and rep["n_warn"] > 0)) else 1

    if a.cmd == "embed":
        con = duckdb.connect(a.db)
        try:
            n = rag_embed(con, embedder=ollama_embedder(a.model), incremental=a.incremental)
        finally:
            con.close()
        print(json.dumps({"db": a.db, "chunks": n}) if a.json else f"embedded {n} chunks into {a.db}")
        return 0

    if a.cmd == "rag":
        con = duckdb.connect(a.db, read_only=True)
        try:
            rows = rag_search(con, a.query, embedder=ollama_embedder(a.model), k=a.k)
        finally:
            con.close()
        if a.json:
            cols = ["path", "title", "chunk_id", "score", "text"]
            print(json.dumps([dict(zip(cols, r)) for r in rows], indent=2, default=str))
        else:
            for path, title, cid, score, text in rows:
                print(f"[{score:.3f}] {path}#{cid} — {title}\n    {text[:160].replace(chr(10),' ')}")
        return 0

    p.print_help(); return 2


if __name__ == "__main__":
    sys.exit(main())
