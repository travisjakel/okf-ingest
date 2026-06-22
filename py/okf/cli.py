#!/usr/bin/env python3
"""okf — command-line interface (Python). Mirrors r/okf/bin/okf.R.

  okf validate <bundle> [--strict] [--json]
  okf ingest   <bundle> --db <path> [--id <id>] [--json]
  okf query    <db> [--sql "..."] [--search <term>] [--concepts] [--links] [--findings] [--json]

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
    i.add_argument("--json", action="store_true")

    q = sub.add_parser("query"); q.add_argument("db")
    q.add_argument("--sql"); q.add_argument("--search")
    q.add_argument("--concepts", action="store_true"); q.add_argument("--links", action="store_true")
    q.add_argument("--findings", action="store_true"); q.add_argument("--json", action="store_true")

    e = sub.add_parser("embed"); e.add_argument("db")
    e.add_argument("--model", default="nomic-embed-text"); e.add_argument("--json", action="store_true")

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

    if a.cmd == "ingest":
        con, s = okf.ingest(a.bundle, db_path=a.db, bundle_id=a.id)
        con.close()
        if a.json:
            print(json.dumps({"bundle": a.bundle, "db": a.db, **s}, indent=2))
        else:
            print(f"ingested {a.bundle} -> {a.db}\n  concepts={s['n_concepts']} "
                  f"conformant={s['n_conformant']} ({s['conformant']}) errors={s['errors']} "
                  f"warnings={s['warnings']} links={s['links_total']} broken={s['links_broken']}")
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

    if a.cmd == "embed":
        con = duckdb.connect(a.db)
        try:
            n = rag_embed(con, embedder=ollama_embedder(a.model))
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
