#!/usr/bin/env python3
"""Conformance check: Python binding vs conformance/expected/*.json.
Run: python conformance/check_py.py  (exit 0 = pass)."""
import os, sys, json, shutil, tempfile
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

# cross-language content-hash parity lock
exp_h = json.load(open(os.path.join(HERE, "expected", "store.json")))["content_hashes"]
got_h = con.execute(
    "SELECT content_hash FROM okf_concept WHERE path='customers.md'").fetchone()[0]
check("store.content_hash[customers.md]", got_h, exp_h["customers.md"])
con.close()

# --- fetch path: ingest the same bundle from a tar archive (offline) ---
_tmp = tempfile.mkdtemp()
_tar = shutil.make_archive(os.path.join(_tmp, "store"), "gztar",
                           os.path.join(HERE, "bundles"), "store")
con3, s3 = okf.ingest(_tar)
check("fetch.tar.n_concepts", s3["n_concepts"], 3)
check("fetch.tar.conformant", s3["conformant"], True)
con3.close()
shutil.rmtree(_tmp, ignore_errors=True)

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

# --- wikilinks ([[name]] resolved by id/alias/title/stem; markdown unchanged) ---
conw, sw = okf.ingest(os.path.join(HERE, "bundles", "wikilinks"))
expw = json.load(open(os.path.join(HERE, "expected", "wikilinks.json")))
check("wikilinks.n_concepts", sw["n_concepts"], expw["bundle"]["n_concepts"])
check("wikilinks.conformant", sw["conformant"], expw["bundle"]["conformant"])
check("wikilinks.links_total", sw["links_total"], expw["links"]["total"])
check("wikilinks.links_broken", sw["links_broken"], expw["links"]["broken"])
wl = {(s, r): d for s, r, d in conw.execute(
    "SELECT src_path, dst_raw, dst_path FROM okf_link").fetchall()}
for key, want in expw["resolutions"].items():
    src, raw = key.split("|", 1)
    check(f"wikilinks.{key}", wl.get((src, raw)), want)
conw.close()

if fails:
    print("FAIL\n  " + "\n  ".join(fails)); sys.exit(1)
print("PASS — Python binding conformant on all fixtures")
