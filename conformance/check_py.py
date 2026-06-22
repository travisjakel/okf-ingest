#!/usr/bin/env python3
"""Conformance check: Python binding vs conformance/expected/*.json.
Run: python conformance/check_py.py  (exit 0 = pass)."""
import os, sys, json
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "py"))
import okf.okf as okf

HERE = os.path.dirname(__file__)
fails = []

def check(name, got, want):
    if got != want:
        fails.append(f"{name}: got {got!r} want {want!r}")

# --- store (conformant) ---
con, s = okf.ingest(os.path.join(HERE, "bundles", "store"))
exp = json.load(open(os.path.join(HERE, "expected", "store.json")))["bundle"]
ver = con.execute("SELECT okf_version FROM okf_bundle").fetchone()[0]
check("store.okf_version", ver, exp["okf_version"])
check("store.n_concepts", s["n_concepts"], exp["n_concepts"])
check("store.n_conformant", s["n_conformant"], exp["n_conformant"])
check("store.conformant", s["conformant"], exp["conformant"])
check("store.errors", s["errors"], 0)
check("store.links_total", s["links_total"], 8)
check("store.links_broken", s["links_broken"], 1)
con.close()

# --- negative ---
con2, s2 = okf.ingest(os.path.join(HERE, "bundles", "negative"))
expn = json.load(open(os.path.join(HERE, "expected", "negative.json")))
check("negative.conformant", s2["conformant"], expn["bundle"]["conformant"])
check("negative.errors", s2["errors"], expn["validation"]["errors"])
rules = dict(con2.execute(
    "SELECT path, rule FROM okf_validation WHERE severity='error'").fetchall())
for er in expn["validation"]["error_rules"]:
    check(f"negative.{er['path']}", rules.get(er["path"]), er["rule"])
con2.close()

if fails:
    print("FAIL\n  " + "\n  ".join(fails)); sys.exit(1)
print("PASS — Python binding conformant on all fixtures")
