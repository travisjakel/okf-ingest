---
title: "Turn a whole book into a queryable knowledge graph with okf-ingest (in Python)"
author: "Travis Jakel"
date: "2026-06-23"
tags: [python, knowledge, duckdb, rag, okf]
---

A long technical book is great to *read* and painful to *query*. Which chapters
cover local methods? Where's the Shapley-value explanation? What links to what?
Instead of grepping, you can turn the book into a small **knowledge graph** —
SQL, graph queries, and semantic search over it — in about thirty lines of
Python, deterministically, with no LLM agent involved.

[**okf-ingest**](https://github.com/travisjakel/okf-ingest) reads an
[Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog)
(OKF) bundle — a folder of markdown files with YAML frontmatter, one concept per
file, markdown links as the graph — into a portable **DuckDB catalog**. Here I
point it at Christoph Molnar's openly-licensed
[*Interpretable Machine Learning*](https://github.com/christophM/interpretable-ml-book)
(CC BY-NC-SA).

> **What is OKF?** [Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog)
> (Google Cloud, v0.1) is a deliberately boring convention: a folder of markdown
> files, **one concept per file**, each with a little YAML frontmatter. The only
> required field is `type`; `title`/`description`/`timestamp`/`tags` are
> recommended. Ordinary markdown **links are the graph**, and two filenames are
> reserved — `index.md` (the map) and `log.md` (the history). That's the whole
> spec: no database, no SDK, no required tooling — if you can `cat` a file, you
> can read OKF. okf-ingest is just a *reader* that turns one of these folders into
> something queryable.

## Step 1 — install, and grab the book

```bash
pip install okf-ingest          # or: uv add okf-ingest
git clone --depth 1 https://github.com/christophM/interpretable-ml-book src
```

## Step 2 — make it OKF (the only "conversion" step)

The book is 47 Quarto `.qmd` chapters grouped into Parts in its `_quarto.yml`. OKF
just wants per-file frontmatter with a `type` and links that form a graph. So:
give each chapter a `type` (its Part — which becomes the graph's colour) and a
title, strip Quarto-only directives, and emit `index.md` → Part pages → chapters.

```python
import os, re, shutil
SRC, OUT, TS = "src/manuscript", "iml-okf", "2025-04-13T00:00:00Z"
PARTS = {
  "Foundations": ["intro","interpretability","goals","overview","data"],
  "Interpretable Models": ["limo","logistic","extend-lm","tree","rules","rulefit"],
  "Local Model-Agnostic Methods": ["ceteris-paribus","ice","lime","counterfactual","anchors","shapley","shap"],
  "Global Model-Agnostic Methods": ["pdp","ale","interaction","decomposition","feature-importance","lofo","global","proto"],
  "Neural Network Interpretation": ["cnn-features","pixel-attribution","detecting-concepts","adversarial","influential"],
  "Beyond the Methods": ["evaluation","storytime","future","translations"],
  "Back Matter": ["cite","acknowledgements"],
  "Appendix": ["what-is-machine-learning","math-terms","r-packages","references"],
}
shutil.rmtree(OUT, ignore_errors=True); os.makedirs(OUT)
pslug = lambda p: "part-" + re.sub(r"[^a-z0-9]+", "-", p.lower())

def clean(lines):                                       # keep prose; links come from structure
    out = []
    for ln in lines:
        if re.match(r"^\s*(\{\{<|:::)", ln): continue   # drop Quarto directives
        ln = re.sub(r"\s*\{#[^}]+\}\s*$", "", ln)       # strip {#label} from headings
        ln = re.sub(r"!\[[^]]*\]\([^)]*\)", "", ln)     # remove image embeds
        out.append(re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", ln))  # de-link to prose
    return out

def fm(t, title): return ["---", f"type: {t}", f'title: "{title.replace(chr(34), chr(39))}"',
                          f"timestamp: {TS}", "tags: [interpretable-ml]", "---", ""]
def write(name, lines):
    open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")

for part, stubs in PARTS.items():
    for stub in stubs:
        raw = open(os.path.join(SRC, stub + ".qmd"), encoding="utf-8").read().splitlines()
        h1 = next((l for l in raw if re.match(r"^#\s", l)), "# " + stub)
        title = re.sub(r"\{#[^}]+\}", "", re.sub(r"^#\s+", "", h1)).strip()
        write(stub + ".md", fm(part, title) + clean(raw))
for part, stubs in PARTS.items():
    write(pslug(part) + ".md", fm("Part", part) + [f"# {part}", ""] + [f"- [{s}]({s}.md)" for s in stubs])
write("index.md", fm("Index", "Interpretable Machine Learning") +
      ["# Interpretable Machine Learning", ""] + [f"- [{p}]({pslug(p)}.md)" for p in PARTS])
```

## Step 3 — ingest, and you have a catalog

From the CLI, or the library:

```bash
okf ingest iml-okf --db iml.duckdb --json
#> { "n_concepts": 49, "links_total": 49, "links_broken": 0, "conformant": true, ... }
```

```python
import okf.okf as okf
con, summary = okf.ingest("iml-okf", db_path="iml.duckdb")
con.execute("""SELECT type, count(*) n FROM okf_concept WHERE reserved = FALSE
               GROUP BY type ORDER BY n DESC""").fetchall()
#> [('Global Model-Agnostic Methods', 8), ('Local Model-Agnostic Methods', 7),
#>  ('Interpretable Models', 6), ('Foundations', 5), ...]
```

It's plain DuckDB — query the concepts, the link graph, or the validation
findings with SQL, from Python or the bare `duckdb` CLI.

## Step 4 — health check (`okf doctor`)

```bash
okf doctor iml-okf
#> health: 100/100  (49/49 concepts clean · 0 errors · 0 warnings)
```

`doctor` is the maintenance gate — broken links, orphans, missing fields, stale
timestamps — with CI exit codes (`--strict`) and an opt-in `--fix` for the
unambiguously-safe repairs. Drop the shipped pre-commit hook / GitHub Action in
and a bundle can't drift broken.

## Step 5 — see it

```bash
okf graph iml-okf --out iml-graph.html      # one self-contained, interactive page
okf export iml-okf --mermaid                # …or a Mermaid diagram for your README
```

![The book as a knowledge graph: index in the centre, the eight Parts as hubs, chapters coloured by Part.](iml-graph.png)

No CDN, no framework — a hand-rolled force-directed canvas you can pan, zoom, and
search; click a node to open its page (`okf html` renders the whole bundle as a
navigable site).

## Step 6 — ask it a question (semantic search)

Optionally embed and retrieve. This is the **one** place a model is used, and
it's a *local, swappable* embedder (Ollama by default) — nothing leaves your
machine:

```bash
okf embed iml.duckdb                                   # 1369 chunks, local nomic-embed-text
okf rag   iml.duckdb --query "How are Shapley values used to explain a prediction?" -k 4
#> [0.852] shapley.md#.. — Shapley Values
#> [0.848] shapley.md#.. — Shapley Values
#> ...
```

## Why this and not an "AI that reads your docs"

okf-ingest is **deterministic and agent-free**: same bundle in → same catalog,
graph, and render out — offline, no API key, reproducible enough to assert on in
CI. It never asks a model to summarise or infer relationships; it reads exactly
the structure the author wrote, and hands *you* the graph (via `okf context`)
when you want to bring your own LLM. The only model touch is the opt-in
`embed`/`rag` layer above.

And it's two bindings over one catalog. The same bundle ingested in **R** gives
the byte-identical result — a parity test enforces it:

```r
install.packages("okf", repos = "https://travisjakel.r-universe.dev")
okf::okf_ingest("iml-okf")$summary$n_concepts   # 49
```

Ingest in Python, query in R, or vice-versa.

---

*okf-ingest is open source (Apache-2.0) on [GitHub](https://github.com/travisjakel/okf-ingest),
[PyPI](https://pypi.org/project/okf-ingest/) and
[R-universe](https://travisjakel.r-universe.dev/okf). The book is* Interpretable
Machine Learning *by Christoph Molnar, used here under CC BY-NC-SA; the conversion
is for demonstration — read the real thing at
<https://christophm.github.io/interpretable-ml-book/>.*
