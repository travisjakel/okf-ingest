#!/usr/bin/env python3
"""Retrieval benchmark for OKF bundles — quality, cost, and run-to-run
stability of the deterministic retrieval stack, with a Monte-Carlo PPR
baseline (how plugin-style sampled PageRank behaves vs okf's exact solver).

Protocol: LEAVE-ONE-LINK-OUT (no labeling, no LLM judge, fully deterministic).
For each evaluation page p (non-reserved, >= --min-out resolved outbound
links): hide p's outbound edges from the graph, ask each method for the top-k
pages related to p, and score against the hidden link targets (Recall@k, MRR).
Reserved pages (index/log) are excluded from candidates and ground truth.

Methods:
  bfs        undirected neighbors of p on the pruned graph (depth 1, then 2),
             discovery order — what okf_context did before 0.8.0
  ppr        exact power-iteration Personalized PageRank from p (okf 0.8.0)
  query-ppr  okf 0.9.0 cascade with p's title+description as the free-text
             query: lexical seeds -> multi-seed exact PPR (p excluded)
  mc-ppr     Monte-Carlo PPR baseline: K random walks with restart from p,
             visit counts as scores (the Obsidian-plugin approach). Run with
             --mc-runs different RNG seeds to measure ranking churn.
  embed      (--embed, needs local Ollama) cosine similarity of page-body
             embeddings — the vector-search alternative

Stability: deterministic methods are run twice and asserted identical;
mc-ppr reports top-k Jaccard churn across seeds.

Usage:
  python bench/retrieval_bench.py <bundle> [<bundle> ...]
      [--k 5 10] [--min-out 2] [--max-pages 150] [--mc-sample 20]
      [--mc-walks 1000 10000] [--mc-runs 10] [--embed] [--json out.json]
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "py"))
import okf                      # noqa: E402
from okf.graph import OKF_STOPWORDS  # noqa: E402

DAMPING = 0.85


# ---------- graph loading -----------------------------------------------------

def load_bundle(path):
    con, _ = okf.ingest(path)
    cps = con.execute(
        "SELECT path, title, description, tags, body, reserved "
        "FROM okf_concept ORDER BY path").fetchall()
    lks = con.execute(
        "SELECT DISTINCT src_path, dst_path FROM okf_link WHERE resolved"
        # OKF_BENCH_BODY_ONLY isolates the SPEC 6.2 frontmatter edges added in
        # 0.12.0, so their effect on retrieval is measured, not assumed.
        + (" AND kind IN ('body','wikilink')" if os.environ.get("OKF_BENCH_BODY_ONLY") else "")
    ).fetchall()
    con.close()
    pages = {r[0]: {"title": r[1], "description": r[2], "tags": r[3],
                    "body": r[4], "reserved": bool(r[5])} for r in cps}
    edges = {(s, d) for s, d in lks if s != d and s in pages and d in pages}
    return pages, edges


def undirected(edges):
    out = set()
    for s, d in edges:
        out.add((s, d))
        out.add((d, s))
    return out


def adjacency(uedges):
    adj = {}
    for s, d in sorted(uedges):
        adj.setdefault(s, []).append(d)
    return adj


# ---------- exact PPR on an explicit edge set (same algorithm as okf.graph.ppr)

def ppr_exact(nodes, adj, seeds, weights=None, damping=DAMPING,
              tol=1e-10, max_iter=100):
    idx = {p: i for i, p in enumerate(nodes)}
    n = len(nodes)
    if weights is None:
        weights = [1.0] * len(seeds)
    seed = [0.0] * n
    for s, w in zip(seeds, weights):
        seed[idx[s]] += w
    tot = sum(seed)
    seed = [x / tot for x in seed]
    deg = {p: len(adj.get(p, [])) for p in nodes}
    p_vec = seed[:]
    for _ in range(max_iter):
        contrib = [0.0] * n
        for s in nodes:
            ps = p_vec[idx[s]]
            if ps and deg[s]:
                share = ps / deg[s]
                for d in adj[s]:
                    contrib[idx[d]] += share
        dangling = sum(p_vec[idx[s]] for s in nodes if not deg[s])
        np_ = [(1 - damping) * seed[i] + damping * (contrib[i] + dangling * seed[i])
               for i in range(n)]
        if sum(abs(np_[i] - p_vec[i]) for i in range(n)) < tol:
            p_vec = np_
            break
        p_vec = np_
    return {p: p_vec[idx[p]] for p in nodes}


# ---------- Monte-Carlo PPR (the plugin-style baseline) ------------------------

def ppr_mc(nodes, adj, seed_page, walks, rng, damping=DAMPING):
    visits = {p: 0 for p in nodes}
    for _ in range(walks):
        cur = seed_page
        while True:
            visits[cur] += 1
            nb = adj.get(cur)
            if not nb or rng.random() > damping:
                break
            cur = nb[rng.randrange(len(nb))]
    return visits


# ---------- lexical seeding (mirrors okf_seeds, over in-memory pages) ----------

def lexical_seeds(pages, query, exclude, k=5):
    import re
    toks = sorted({t for t in re.findall(r"[a-z0-9]+", query.lower())
                   if len(t) >= 3 and t not in OKF_STOPWORDS})
    out = []
    for path in sorted(pages):
        v = pages[path]
        if v["reserved"] or path == exclude:
            continue
        ttl = (v["title"] or "").lower()
        dsc = (v["description"] or "").lower()
        tgs = (v["tags"] or "").lower()
        bod = (v["body"] or "").lower()
        sc = 0
        for t in toks:
            if t in ttl:
                sc += 3
            if t in dsc or t in tgs:
                sc += 2
            if t in bod:
                sc += 1
        if sc > 0:
            out.append((path, float(sc)))
    out.sort(key=lambda r: (-r[1], r[0]))
    return out[:k]


# ---------- retrieval methods (return ranked candidate lists) ------------------

def rank_from_scores(scores, exclude, pages):
    cands = [(p, s) for p, s in scores.items()
             if s > 0 and p not in exclude and not pages[p]["reserved"]]
    cands.sort(key=lambda r: (-r[1], r[0]))
    return [p for p, _ in cands]


def method_bfs(pages, adj, p):
    seen, order, frontier = {p}, [], [p]
    for _ in range(2):                       # depth 1 then 2, discovery order
        nxt = []
        for x in frontier:
            for nb in adj.get(x, []):
                if nb not in seen:
                    seen.add(nb)
                    if not pages[nb]["reserved"]:
                        order.append(nb)
                    nxt.append(nb)
        frontier = nxt
    return order


def method_ppr(pages, nodes, adj, p):
    return rank_from_scores(ppr_exact(nodes, adj, [p]), {p}, pages)


def method_query_ppr(pages, nodes, adj, p):
    q = f'{pages[p]["title"] or ""} {pages[p]["description"] or ""}'
    seeds = lexical_seeds(pages, q, exclude=p)
    if not seeds:
        return []
    scores = ppr_exact(nodes, adj, [s for s, _ in seeds], [w for _, w in seeds])
    return rank_from_scores(scores, {p}, pages)


def method_mc(pages, adj, p, walks, seed):
    rng = random.Random(seed)
    visits = ppr_mc(sorted(pages), adj, p, walks, rng)
    return rank_from_scores({k: float(v) for k, v in visits.items()}, {p}, pages)


# ---------- optional embeddings method -----------------------------------------

def build_embeddings(pages, model="nomic-embed-text"):
    from okf.rag import ollama_embedder
    emb = ollama_embedder(model)
    vecs = {}
    for path in sorted(pages):
        if pages[path]["reserved"]:
            continue
        text = (pages[path]["body"] or "")[:2000] or (pages[path]["title"] or path)
        vecs[path] = emb([text])[0]
    return vecs


def method_embed(vecs, p, pages):
    import math
    if p not in vecs:
        return []
    a = vecs[p]
    na = math.sqrt(sum(x * x for x in a))
    scored = []
    for q, b in vecs.items():
        if q == p:
            continue
        nb = math.sqrt(sum(x * x for x in b))
        dot = sum(x * y for x, y in zip(a, b))
        scored.append((q, dot / (na * nb) if na and nb else 0.0))
    scored.sort(key=lambda r: (-r[1], r[0]))
    return [q for q, _ in scored]


# ---------- metrics -------------------------------------------------------------

def recall_at(ranked, truth, k):
    return len(set(ranked[:k]) & truth) / len(truth)


def mrr(ranked, truth):
    for i, r in enumerate(ranked, 1):
        if r in truth:
            return 1.0 / i
    return 0.0


def jaccard(a, b):
    a, b = set(a), set(b)
    return len(a & b) / len(a | b) if a | b else 1.0


# ---------- main ----------------------------------------------------------------

def bench_bundle(path, ks, min_out, max_pages, mc_sample, mc_walks, mc_runs,
                 do_embed):
    pages, edges = load_bundle(path)
    nodes = sorted(pages)
    out_links = {}
    for s, d in edges:
        if not pages[s]["reserved"] and not pages[d]["reserved"]:
            out_links.setdefault(s, set()).add(d)
    eval_pages = sorted(p for p, t in out_links.items()
                        if len(t) >= min_out and not pages[p]["reserved"])[:max_pages]
    print(f"\n== {path} — {len(nodes)} pages, {len(edges)} edges, "
          f"{len(eval_pages)} eval pages (LOLO, min_out={min_out}) ==")
    if not eval_pages:
        return None

    vecs = None
    if do_embed:
        t0 = time.perf_counter()
        try:
            vecs = build_embeddings(pages)
            print(f"   embeddings built: {len(vecs)} pages in {time.perf_counter()-t0:.1f}s")
        except Exception as e:
            print(f"   embeddings SKIPPED ({type(e).__name__}: {e})")

    methods = ["bfs", "ppr", "query-ppr"] + (["embed"] if vecs else [])
    res = {m: {"r": {k: [] for k in ks}, "mrr": [], "ms": []} for m in methods}
    stable = {m: True for m in methods}

    for p in eval_pages:
        truth = out_links[p]
        pruned = {(s, d) for s, d in edges if s != p}   # hide p's outbound edges
        adj = adjacency(undirected(pruned))
        for m in methods:
            def run():
                if m == "bfs":
                    return method_bfs(pages, adj, p)
                if m == "ppr":
                    return method_ppr(pages, nodes, adj, p)
                if m == "query-ppr":
                    return method_query_ppr(pages, nodes, adj, p)
                return method_embed(vecs, p, pages)
            t0 = time.perf_counter()
            ranked = run()
            res[m]["ms"].append((time.perf_counter() - t0) * 1000)
            if ranked != run():                          # determinism assertion
                stable[m] = False
            for k in ks:
                res[m]["r"][k].append(recall_at(ranked, truth, k))
            res[m]["mrr"].append(mrr(ranked, truth))

    # Monte-Carlo baseline: quality + churn on a sample of eval pages
    mc = {}
    sample = eval_pages[:mc_sample]
    kk = ks[0]
    for walks in mc_walks:
        r_at, churn, exact_agree = [], [], []
        for p in sample:
            truth = out_links[p]
            pruned = {(s, d) for s, d in edges if s != p}
            adj = adjacency(undirected(pruned))
            exact_top = method_ppr(pages, nodes, adj, p)[:kk]
            tops = []
            for seed in range(mc_runs):
                ranked = method_mc(pages, adj, p, walks, seed)
                tops.append(ranked[:kk])
                r_at.append(recall_at(ranked, truth, kk))
            churn += [jaccard(tops[i], tops[i + 1]) for i in range(len(tops) - 1)]
            exact_agree += [jaccard(t, exact_top) for t in tops]
        mc[walks] = {
            f"r@{kk}": sum(r_at) / len(r_at),
            f"top{kk}_jaccard_between_runs": sum(churn) / len(churn),
            f"top{kk}_jaccard_vs_exact": sum(exact_agree) / len(exact_agree),
        }

    # report
    hdr = f"   {'method':<10}" + "".join(f"  R@{k:<4}" for k in ks) + \
          "   MRR    ms/q   identical-reruns"
    print(hdr)
    for m in methods:
        row = f"   {m:<10}"
        for k in ks:
            row += f"  {sum(res[m]['r'][k])/len(res[m]['r'][k]):.3f} "
        row += f"  {sum(res[m]['mrr'])/len(res[m]['mrr']):.3f}"
        row += f"  {sum(res[m]['ms'])/len(res[m]['ms']):6.1f}"
        row += f"   {'yes' if stable[m] else 'NO'}"
        print(row)
    print(f"   mc-ppr baseline ({len(sample)} pages x {mc_runs} seeds):")
    for walks, v in mc.items():
        print(f"     K={walks:<6} R@{kk}={v[f'r@{kk}']:.3f}  "
              f"run-to-run top-{kk} Jaccard={v[f'top{kk}_jaccard_between_runs']:.3f}  "
              f"vs exact={v[f'top{kk}_jaccard_vs_exact']:.3f}")

    return {"bundle": path, "n_pages": len(nodes), "n_eval": len(eval_pages),
            "methods": {m: {"recall": {str(k): sum(res[m]["r"][k]) / len(res[m]["r"][k]) for k in ks},
                            "mrr": sum(res[m]["mrr"]) / len(res[m]["mrr"]),
                            "ms_per_query": sum(res[m]["ms"]) / len(res[m]["ms"]),
                            "deterministic": stable[m]} for m in methods},
            "mc_ppr": {str(w): v for w, v in mc.items()}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundles", nargs="+")
    ap.add_argument("--k", type=int, nargs="+", default=[5, 10])
    ap.add_argument("--min-out", type=int, default=2)
    ap.add_argument("--max-pages", type=int, default=150)
    ap.add_argument("--mc-sample", type=int, default=20)
    ap.add_argument("--mc-walks", type=int, nargs="+", default=[1000, 10000])
    ap.add_argument("--mc-runs", type=int, default=10)
    ap.add_argument("--embed", action="store_true")
    ap.add_argument("--json", default=None)
    a = ap.parse_args()

    results = []
    for b in a.bundles:
        r = bench_bundle(b, a.k, a.min_out, a.max_pages, a.mc_sample,
                         a.mc_walks, a.mc_runs, a.embed)
        if r:
            results.append(r)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(results, fh, indent=2)
        print(f"\nwrote {a.json}")


if __name__ == "__main__":
    main()
