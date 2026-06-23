# okf-ingest

[![CI](https://github.com/travisjakel/okf-ingest/actions/workflows/ci.yml/badge.svg)](https://github.com/travisjakel/okf-ingest/actions/workflows/ci.yml)
[![r-universe](https://travisjakel.r-universe.dev/okf/badges/version)](https://travisjakel.r-universe.dev/okf)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

A unified, open-source **ingestion tool for [Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog) (OKF) bundles** — read any OKF bundle, validate its conformance (permissively, per the spec), build the concept graph, and load it into a portable, queryable **DuckDB catalog**. One catalog format, two idiomatic bindings: **R** and **Python**.

OKF (Google Cloud, v0.1) is a directory of markdown files with YAML frontmatter — one concept per file, markdown links as a graph. Validators and parsers already exist (Node, a web tool, a pure-Rust crate). **What no other tool does — and what this one is for — is load a bundle into a SQL-queryable DuckDB catalog with built-in semantic search (RAG), and do it from R or Python** (there was no R or Python OKF tooling at all). See [Related tools](#related-tools).

## Deterministic by design — no agents

okf-ingest is **pure, deterministic machinery**: the same bundle in always
produces the same catalog, the same graph, the same clusters, and the same
rendered HTML out — byte-for-byte, on any machine, with no network and no API
key. **There are no LLM agents anywhere in it.** It never asks a model to
summarize a page, infer a "layer," guess a relationship, or decide anything. It
reads exactly the structure the author wrote — the frontmatter, the markdown
links — and surfaces *that*.

This is a deliberate line. A wave of tools will read your knowledge base by
turning agents loose to summarize and "understand" it; their output is
non-reproducible, costs tokens, ships your corpus to a model, and quietly
invents structure. okf-ingest does the opposite — it's the boring, auditable
substrate underneath:

- **Reproducible** — deterministic enough to assert on in CI; a parity test locks
  R and Python to byte-identical catalogs. No "re-ran it and got different
  edges."
- **Free & offline** — no tokens, no keys, no calls. Parsing, validation, the
  link graph, community clustering (deterministic label propagation), backlinks,
  impact, and HTML/graph rendering are all plain code.
- **Private** — your content never leaves the machine. Nothing is sent anywhere.
- **Composable with agents, not replaced by them** — when you *do* want an LLM,
  okf hands it the curated graph to reason over (`okf context`) rather than
  pretending to be the reasoner. You bring the model; okf brings the ground truth.

**The two honest exceptions**, both opt-in and explicit: the `embed`/`rag` layer
calls a *local, pluggable* embedding model (default Ollama — swap in your own) to
add vector search; and `ingested_at` is a wall-clock metadata field you can
override (the conformance suite does, which is how it stays byte-stable). The
knowledge representation itself — concepts, graph, clusters, render — is 100%
deterministic and model-free.

## Do you actually need RAG?

Often you don't — by design. OKF bundles are meant to be read *directly* by an
agent: load `index.md`, follow the curated links, pull the few relevant concept
files into context. For a small, well-linked bundle (dozens to low-hundreds of
concepts), that index-first traversal is the intended pattern — cf. Karpathy's
"LLM wiki"; Google's own framing is that OKF **complements** RAG, it doesn't
require it. No catalog, no embeddings, no okf-ingest — just let the agent
navigate the markdown.

Reach for okf-ingest when direct reading isn't enough:

- **Programmatic / SQL access** (any size) — query concepts, the link graph, or
  conformance findings from code or CI, in R or Python. → the DuckDB catalog.
- **Large bundles** — thousands of concepts, where loading the index or the whole
  bundle into context isn't practical.
- **Semantic / cross-corpus retrieval** — feeding OKF into a wider RAG pipeline,
  or similarity search over a big/heterogeneous knowledge base. → the optional
  `embed`/`rag` layer.

For small curated bundles, **skip `embed`/`rag`** — the explicit graph the author
wrote beats fuzzy vector matches, and following links costs nothing. If you want
tooling *for* that wiki pattern (rather than against it), use
[`okf context`](#context--the-index-first-no-embeddings-primitive): it assembles
the index-first, link-following slice for an agent to read directly — no
embeddings involved.

## Quickstart

One tool, two bindings — use whichever you live in.

**R** — from [R-universe](https://travisjakel.r-universe.dev):

```r
install.packages("okf", repos = c(travisjakel = "https://travisjakel.r-universe.dev",
                                  CRAN = "https://cloud.r-project.org"))
library(okf)

res <- okf_ingest("my-bundle", db_path = "kb.duckdb")   # dir, git URL, or tar/zip
okf_embed(res$con)                                       # local Ollama nomic-embed-text
okf_rag(res$con, "how is revenue computed?", k = 3)[, c("path", "title", "score")]
#>                 path   title score
#> 1 metrics/revenue.md Revenue 0.709
#> 2          orders.md  Orders 0.642
```

**Python / CLI** — from [PyPI](https://pypi.org/project/okf-ingest/):

```bash
pip install okf-ingest

okf ingest ./my-bundle --db kb.duckdb      # dir, git URL, or tar/zip
okf embed  kb.duckdb
okf rag    kb.duckdb --query "how is revenue computed?" -k 5
# [0.71] metrics/revenue.md#1 — Revenue
# [0.64] orders.md#1 — Orders
```

The catalog is plain DuckDB — query it with SQL, R, Python, or the bare `duckdb`
CLI. Ingest/embed in one language, query from the other.

## Why "core + bindings" without a binary core

The interoperability **core is a contract, not compiled code**:

1. **`schema/catalog.sql`** — the DuckDB catalog schema. Both bindings write matching catalogs (same rows, types, links, validation, and `content_hash` — a parity-locked conformance test enforces this); the `frontmatter` JSON column is semantically equal but not byte-for-byte identical across languages. You can query the catalog with the bare `duckdb` CLI, no library at all.
2. **`conformance/`** — language-agnostic golden bundles + expected outputs that every binding must reproduce.

The **bindings** (`r/okf`, `py/okf`) are thin, native, ~300-line packages kept in lockstep by that shared corpus. This matches OKF's own ethos ("no required tooling — if you can `cat` a file you can read OKF") far better than a heavyweight FFI core would.

## What it enforces (and tolerates)

Per OKF §6, a bundle is **conformant** iff every non-reserved `.md` has parseable YAML frontmatter with a **non-empty `type`** (a free string — no enum). Everything else is permissive: missing recommended fields, unknown types/keys, broken links, and missing `index.md` produce **findings, never rejection**. See [`docs/SPEC_NOTES.md`](docs/SPEC_NOTES.md).

## Install

```bash
# Python — installs the `okf` command + importable package
pip install ./py            # (or: pip install okf-ingest once published)

# R — from R-universe (binaries; pulls deps automatically)
options(repos = c(travisjakel = "https://travisjakel.r-universe.dev",
                  CRAN = "https://cloud.r-project.org"))
install.packages("okf")
# …or from a clone:
R CMD INSTALL r/okf         # (or: remotes::install_local("r/okf"))
```

Optional extras: `pip install okf-ingest[html]` (or R `install.packages("commonmark")`)
adds the markdown engine for `okf html`; embeddings/`rag` use a local Ollama
server (no extra Python dep; R uses the `httr2` Suggests).

Both bindings can also be used without installing (dev mode): `source("r/okf/R/okf.R")`
in R, or `PYTHONPATH=py python -m okf …` for the Python CLI.

## Usage

**R**
```r
source("r/okf/R/okf.R")
res <- okf_ingest("path/to/bundle", db_path = "catalog.duckdb")
res$summary                       # n_concepts, conformant, errors, links_broken, ...
okf_search(res$con, "revenue")    # full-text-ish lookup over bodies
okf_findings(res$con)             # conformance findings
```

**Python**
```python
import okf.okf as okf
con, summary = okf.ingest("path/to/bundle", db_path="catalog.duckdb")
okf.search(con, "revenue")
```

Both produce the same `okf_bundle / okf_concept / okf_link / okf_validation` tables.

### Semantic search (RAG)

> Optional, and overkill for small curated bundles — see
> [Do you actually need RAG?](#do-you-actually-need-rag). It pays off for large
> or cross-corpus knowledge bases, not a hand-linked folder of a few dozen concepts.

`embed` chunks concept bodies (paragraph-merged to ~600 chars), embeds each via
a **pluggable embedder** (default: local Ollama `nomic-embed-text`, 768-dim;
swap in any `texts -> list[vector]` callable), and stores vectors in `okf_chunk`.
`rag` embeds a query and ranks chunks by cosine similarity using DuckDB's native
`list_cosine_similarity` — **no vector-DB extension required**. Embeddings are
part of the shared catalog, so you can embed with one binding and query with the
other.

## CLI

Identical subcommands in both languages — after install just `okf …` (Python
console script); in R via `Rscript r/okf/bin/okf.R …` (uses the installed
package, or falls back to dev source):

```bash
okf validate <bundle> [--strict] [--json]      # lint; exit 1 on errors (or warnings w/ --strict)
okf ingest   <source> --db catalog.duckdb [--subdir <p>] [--branch <b>] [--incremental] [--json]
okf query    catalog.duckdb [--sql "…"] [--search <term>] [--concepts|--links|--findings] [--json]
okf context  <bundle|catalog> [--start <concept>] [--depth N] [--max-tokens N]  # LLM-wiki context blob
okf html     <bundle|catalog> --out <dir> | --single <file.html> [--title T]    # render for viewing
okf graph    <bundle|catalog> --out <file.html> [--title T]                     # interactive force-directed graph
okf export   <bundle|catalog> [--json]                      # portable {nodes, edges} graph JSON
okf impact   <bundle|catalog> <concept> [--json]            # inbound / outbound / transitive ripple
okf embed    catalog.duckdb [--model nomic-embed-text] [--incremental]  # chunk + embed bodies for search
okf rag      catalog.duckdb --query "…" [-k 5] [--model …]  # top-k semantic matches
```

### `context` — the index-first, no-embeddings primitive

`context` is the faithful OKF / "LLM wiki" consume operation: hand an agent
`index.md` plus a concept and its **link-neighborhood**, assembled into one
markdown blob to read directly. It walks the concept graph you already built —
**no embeddings, no vector search** — and is capped to a token budget. This is
the on-concept alternative to `rag` for curated bundles:

```bash
okf context ./my-bundle --start orders.md --depth 1 --max-tokens 8000 > ctx.md
# emits index.md + orders.md + everything one link away, ready to paste into a prompt
```

It accepts a bundle directly (dir/git/tar/zip) or an ingested `.duckdb` catalog.

### `html` — render a bundle for viewing

`html` is a thin "render for viewing" layer: turn a bundle into browsable HTML
with **no build step, no JavaScript, inline CSS** — copy the output anywhere and
open it. Two modes:

```bash
okf html ./my-bundle --out site/            # navigable site: one .html per concept + index.html
okf html ./my-bundle --single bundle.html   # one self-contained file (concepts become anchored sections)
```

Internal `.md` links are rewritten to **page-relative** `.html` (site) or
in-page `#anchors` (single), so the result works straight off the filesystem
(`file://`) however the source wrote its links. Each page gets a metadata bar
(type / status / timestamp / tags), a **"Linked from"** backlinks line, and a
footer badge that surfaces broken or orphan links from `validate`. Bodies render
via a thin markdown engine (R `commonmark`, a Suggests dep; Python `markdown` via
the `okf-ingest[html]` extra). Like `context`, it accepts a bundle
(dir/git/tar/zip) or a `.duckdb` catalog.

### `graph` / `export` / `impact` — the concept graph, surfaced

The catalog already holds the link graph; these expose it (all **deterministic**,
no LLM):

```bash
okf graph  ./my-bundle --out graph.html   # interactive force-directed page (vanilla JS, no CDN)
okf export ./my-bundle > graph.json       # portable {nodes, edges} for any external visualizer
okf impact ./my-bundle signals/x.md       # outbound / inbound / transitive ripple of a concept
```

`graph` is a single self-contained HTML page — pan/zoom/drag, type-to-search,
nodes coloured by OKF type with community clustering as the fallback (a
deterministic label-propagation, [`okf_clusters`]). Click a node to open its
rendered `.html`, so dropping `graph.html` into a `html --out` site root turns it
into a live map. `export` emits the same node/edge model as JSON (nodes carry
`id`/`type`/`title`/`tags`/`cluster`/`href`), extending the "core is a contract"
idea beyond the DuckDB catalog. `impact` answers "what does changing this ripple
to" from the resolved-link graph.

### `--incremental` — re-ingest / re-embed only what changed

`ingest --incremental` diffs each concept's `content_hash` against a prior ingest
into the same `--db`, rewriting only changed/added concepts (and dropping removed
ones); the JSON summary reports `changed`/`added`/`removed`/`cached`. `embed
--incremental` re-embeds only concepts whose content changed, skipping the
expensive embedder calls for the rest — the right default for large, often-edited
wikis.

A `<source>` is a local directory, a **git URL** (github/gitlab/bitbucket, `.git`,
or `git@`), or a **tar/zip archive** (local path or `http(s)` URL). Remote sources
are fetched to a temp dir and cleaned up automatically; `--subdir` selects a
bundle within a repo/archive and `--branch` picks a git ref:

```bash
okf ingest https://github.com/org/repo.git --subdir docs/okf --db kb.duckdb
okf ingest https://example.com/bundle.tar.gz --db kb.duckdb
```

`validate` is CI-friendly (non-zero exit = non-conformant). The catalog is
**portable across bindings** — ingest with R, query with Python, or vice-versa:

```bash
Rscript r/okf/bin/okf.R ingest ./bundle --db cat.duckdb   # R writes
okf query cat.duckdb --search revenue                     # Python reads
```

## Conformance tests

```bash
Rscript conformance/check_r.R       # R binding vs expected/*.json
python  conformance/check_py.py     # Python binding vs expected/*.json
```

## Layout

```
schema/catalog.sql      core: the catalog schema (interop contract)
conformance/            core: golden bundles + expected outputs + per-lang checks
docs/                   ARCHITECTURE.md, SPEC_NOTES.md
r/okf/                  R binding
py/okf/                 Python binding
```

## Status

Consume → validate → load → query → **embed → RAG** is implemented, CLI-wrapped,
and conformance-tested in both languages, all over one portable DuckDB catalog
(embed in either binding, query from the other). Roadmap: git/tar/zip bundle
readers (`source_kind` is in the schema; only `dir` today) and packaging
(`pyproject.toml` / R `DESCRIPTION`).

## Related tools

The OKF tooling ecosystem appeared within weeks of the v0.1 spec. okf-ingest is
deliberately positioned where the others aren't — a queryable catalog + RAG, in
R and Python:

| Tool | Lang | Validate | Parse/graph | Queryable store | Embeddings / RAG |
|------|------|:--:|:--:|:--:|:--:|
| `GoogleCloudPlatform/knowledge-catalog` | Py/TS | — | producer + HTML viz | — | — |
| `W4G1/okf` | Rust | ✓ | ✓ | — | — |
| `sniperunder123/okf-knowledge` | Python (Claude Code skill) | ✓ | ✓ + **authoring & graph viz** | — | — |
| WitsCode / okf.site | Node/web | ✓ | partial | — | — |
| okf-skills / okf-skill | agent skills | ✓ | ✓ | — | — |
| **okf-ingest** (this) | **R + Python** | ✓ | ✓ | **DuckDB catalog** | **✓** |

okf-ingest sits on the **consume** side of the OKF lifecycle. For the **produce**
side — authoring, maintaining, and visualizing bundles (especially inside Claude
Code) — [`okf-knowledge`](https://github.com/sniperunder123/okf-knowledge) is a
nice complement: curate a bundle there, then `okf ingest` it into a queryable
DuckDB + RAG catalog here. If you only need to lint a bundle, the Rust/Node
validators are great.

## License

Apache-2.0 (matching the OKF reference implementation). See `LICENSE`.
