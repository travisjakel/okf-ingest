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

# --- v0.2 (generated/sources/verified families; generated.at timestamp fallback) ---
conv, sv = okf.ingest(os.path.join(HERE, "bundles", "v02"))
expv = json.load(open(os.path.join(HERE, "expected", "v02.json")))
ver_v = conv.execute("SELECT okf_version FROM okf_bundle").fetchone()[0]
check("v02.okf_version", ver_v, expv["bundle"]["okf_version"])
check("v02.n_concepts", sv["n_concepts"], expv["bundle"]["n_concepts"])
check("v02.n_conformant", sv["n_conformant"], expv["bundle"]["n_conformant"])
check("v02.conformant", sv["conformant"], expv["bundle"]["conformant"])
check("v02.errors", sv["errors"], expv["validation"]["errors"])
check("v02.warnings", sv["warnings"], expv["validation"]["warnings"])
check("v02.links_total", sv["links_total"], expv["links"]["total"])
check("v02.links_broken", sv["links_broken"], expv["links"]["broken"])
rules_v = {r[0] for r in conv.execute("SELECT DISTINCT rule FROM okf_validation").fetchall()}
for fr in expv["validation"]["forbidden_rules"]:
    check(f"v02.no_{fr}", fr in rules_v, False)
ts_v = dict(conv.execute("SELECT path, timestamp FROM okf_concept").fetchall())
for pth, want in expv["timestamps"].items():
    if pth.startswith("_"):
        continue
    check(f"v02.timestamp[{pth}]", ts_v.get(pth), want)
conv.close()

# --- rank (Personalized PageRank: exact, deterministic, parity-locked) ---
from okf.graph import ppr as okf_ppr  # noqa: E402
conr, _ = okf.ingest(os.path.join(HERE, "bundles", "store"))
expr = json.load(open(os.path.join(HERE, "expected", "rank.json")))
got_rank = [{"path": r["path"], "score": round(r["score"], 8)}
            for r in okf_ppr(conr, expr["start"], damping=expr["damping"], k=10)]
check("rank.ranking", got_rank, expr["ranking"])
conr.close()

# --- query seeding (lexical seeds -> multi-seed PPR, parity-locked) ---
from okf.graph import seeds as okf_seeds  # noqa: E402
conq, _ = okf.ingest(os.path.join(HERE, "bundles", "store"))
expq = json.load(open(os.path.join(HERE, "expected", "query.json")))
got_seeds = [{"path": x["path"], "score": x["score"]} for x in okf_seeds(conq, expq["query"])]
check("query.seeds", got_seeds, expq["seeds"])
got_qr = [{"path": x["path"], "score": round(x["score"], 8)}
          for x in okf_ppr(conq, [x["path"] for x in got_seeds],
                           weights=[x["score"] for x in got_seeds], k=10)]
check("query.ranking", got_qr, expq["ranking"])
conq.close()

# --- diff (deterministic concept-level changelog between two bundle states) ---
from okf.diff import diff as okf_diff  # noqa: E402
dd = okf_diff(os.path.join(HERE, "bundles", "diff_a"), os.path.join(HERE, "bundles", "diff_b"))
expd = json.load(open(os.path.join(HERE, "expected", "diff.json")))
check("diff.identical", dd["identical"], expd["identical"])
for k in ("added", "removed", "changed"):
    check(f"diff.{k}", dd[k], expd[k])
check("diff.type_changed", [f"{t['path']}|{t['from']}|{t['to']}" for t in dd["type_changed"]],
      expd["type_changed"])
check("diff.retitled", [f"{t['path']}|{t['from']}|{t['to']}" for t in dd["retitled"]],
      expd["retitled"])
for k, c2 in (("links_added", "dst_path"), ("links_removed", "dst_path"),
              ("broken_added", "dst_raw"), ("broken_fixed", "dst_raw")):
    check(f"diff.{k}", [f"{l['src_path']}|{l[c2]}" for l in dd[k]], expd[k])
# drift mode: a catalog diffed against its own source directory is identical
cond, _ = okf.ingest(os.path.join(HERE, "bundles", "diff_a"))
d0 = okf_diff(cond, os.path.join(HERE, "bundles", "diff_a"))
check("diff.drift_identical", d0["identical"], True)
cond.close()

# v0.2 Attested Computation: SPEC 6.2 path-valued frontmatter fields as graph
# edges, non-concept targets, scope descriptors, both computation forms.
cona, sa = okf.ingest(os.path.join(HERE, "bundles", "v02_attested"))
expa = json.load(open(os.path.join(HERE, "expected", "v02_attested.json")))
check("v02a.n_files", sa["n_files"], expa["bundle"]["n_files"])
check("v02a.n_concepts", sa["n_concepts"], expa["bundle"]["n_concepts"])
check("v02a.n_conformant", sa["n_conformant"], expa["bundle"]["n_conformant"])
check("v02a.conformant", sa["conformant"], expa["bundle"]["conformant"])
check("v02a.errors", sa["errors"], expa["validation"]["errors"])
check("v02a.warnings", sa["warnings"], expa["validation"]["warnings"])
check("v02a.links_total", sa["links_total"], expa["links"]["total"])
check("v02a.links_broken", sa["links_broken"], expa["links"]["broken"])
rules_a = {r[0] for r in cona.execute("SELECT DISTINCT rule FROM okf_validation").fetchall()}
for fr in expa["validation"]["forbidden_rules"]:
    check("v02a.no_" + fr, fr in rules_a, False)
rc = dict(cona.execute("SELECT rule, COUNT(*) FROM okf_validation GROUP BY rule").fetchall())
for rl, n in expa["validation"]["rule_counts"].items():
    check("v02a.rule[" + rl + "]", rc.get(rl, 0), n)
bk = dict(cona.execute("SELECT kind, COUNT(*) FROM okf_link GROUP BY kind").fetchall())
for kd, n in expa["links"]["by_kind"].items():
    check("v02a.kind[" + kd + "]", bk.get(kd, 0), n)
bt = dict(cona.execute("SELECT target, COUNT(*) FROM okf_link GROUP BY target").fetchall())
for tg, n in expa["links"]["by_target"].items():
    check("v02a.target[" + tg + "]", bt.get(tg, 0), n)
la = {r[0] + "|" + r[1]: r[2] for r in
      cona.execute("SELECT src_path, dst_raw, dst_path FROM okf_link").fetchall()}
for key, want in expa["resolutions"].items():
    if key.startswith("_"):
        continue
    check("v02a." + key, la.get(key), want)
ts_a = dict(cona.execute("SELECT path, timestamp FROM okf_concept").fetchall())
for pth, want in expa["timestamps"].items():
    if pth.startswith("_"):
        continue
    check("v02a.timestamp[" + pth + "]", ts_a.get(pth), want)
cona.close()

# yaml_scalars: YAML 1.2 core-schema booleans, identical in every binding.
cony, sy = okf.ingest(os.path.join(HERE, "bundles", "yaml_scalars"))
expy = json.load(open(os.path.join(HERE, "expected", "yaml_scalars.json")))
check("ys.n_concepts", sy["n_concepts"], expy["bundle"]["n_concepts"])
check("ys.conformant", sy["conformant"], expy["bundle"]["conformant"])
fmy = json.loads(cony.execute(
    "SELECT frontmatter FROM okf_concept WHERE path='scalars.md'").fetchone()[0])
for k, want in expy["strings_every_binding"].items():
    check("ys.str[" + k + "]", fmy.get(k), want)
for k, want in expy["booleans_typed_bindings"].items():
    check("ys.bool[" + k + "]", fmy.get(k), want)
check("ys.parameter_names", [p["name"] for p in fmy["parameters"]], expy["parameter_names"])
check("ys.parameter_required", [p["required"] for p in fmy["parameters"]],
      expy["parameter_required_typed"])
cony.close()

if fails:
    print("FAIL\n  " + "\n  ".join(fails)); sys.exit(1)
print("PASS — Python binding conformant on all fixtures")
