# Architecture

## The decision: "core + bindings" as a *contract*, not a binary

A literal core+bindings design (Rust/C core, `extendr`/`pyo3` bindings) was
rejected. For an OKF ingestion tool it's the wrong trade: parsing markdown+YAML
and loading a DB is light glue, an R-native maintainer shouldn't carry a Rust
toolchain, and a heavy required binary contradicts OKF's "no required tooling"
ethos.

Instead the **core is two portable, language-neutral artifacts**, and the
**bindings are thin native packages** held to the core by tests:

| Layer | Artifact | Role |
|-------|----------|------|
| Core  | `schema/catalog.sql` | The DuckDB catalog schema — the interop contract. Both bindings emit identical catalogs; queryable with the bare `duckdb` CLI. |
| Core  | `conformance/` | Golden bundles + `expected/*.json`. The behavioral contract every binding reproduces. |
| Binding | `r/okf/` | R: yaml, DBI, duckdb, digest, jsonlite. |
| Binding | `py/okf/` | Python: pyyaml, duckdb (stdlib hashlib/json). |

A new binding (TS, Go, …) is conformant the moment it produces the same catalog
and passes `conformance/`.

## Data flow (identical in both bindings)

```
bundle dir ─▶ read ─▶ parse frontmatter (YAML)         ─┐
                      extract markdown links            │
                      resolve links (abs / rel / extern)│
              ─▶ validate (OKF §6 hard rules + soft)    ├─▶ DuckDB catalog
              ─▶ ingest:  okf_bundle / okf_concept /     │   (okf_*) ─▶ query / RAG
                          okf_link / okf_validation     ─┘            ─▶ context (LLM blob)
                                                                      ─▶ html (render for viewing)
```

## Consume layers (all read the same catalog)

The catalog has three consume paths, each a thin reader over the `okf_*` tables —
none re-parses the bundle:

| Layer | Function | Reads | Output |
|-------|----------|-------|--------|
| Semantic | `okf_rag` / `rag` | `okf_chunk` (embeddings) | top-k chunks |
| Context | `okf_context` / `context` | `okf_concept` + `okf_link` | index-first markdown blob for an LLM |
| Render | `okf_html` / `render_html` | `okf_concept` + `okf_validation` + `okf_link` | static HTML (site or single file) |
| Graph | `okf_graph_html` / `okf_graph_json` / `okf_backlinks` / `okf_impact` / `okf_clusters` | `okf_concept` + `okf_link` | force-directed page · `{nodes,edges}` JSON · backlinks · ripple · communities |

All **deterministic** — no LLM, no model calls. Community detection is
synchronous label propagation with lexicographic tie-breaking (reproducible);
the graph page colours by OKF `type` with community as the fallback. This is the
deliberate line vs. LLM-agent "understand my wiki" tools: okf surfaces the graph
the human authored and hands it to *your* LLM via `context`/`rag` — it does not
generate summaries, entities, or claims itself.

**Incremental.** `okf_chunk` carries each concept's `content_hash`, and
`okf_concept` rows are keyed by `(bundle_id, path)`. `ingest --incremental` and
`embed --incremental` diff those hashes against the prior catalog and touch only
what changed; links and validation are always recomputed (cheap, graph-global).
A full `ingest` is an idempotent replace of the bundle's rows.

`okf_html` is deliberately the thinnest of the three: it rewrites internal `.md`
links to page-relative `.html` (site) or `#anchors` (single), wraps each concept
in a metadata bar + validation-derived footer badge, and inlines one CSS string
(mirrored across bindings like `OKF_SCHEMA`). No JS, no build step — the only new
dependency is a markdown engine, optional and guarded (`commonmark` Suggests in
R; the `okf-ingest[html]` extra in Python). Link resolution reuses
`okf_resolve_link`, so the rendered graph matches the validated graph exactly.

## Parity notes (where the two languages had to be aligned)

- **Timestamps**: PyYAML coerces ISO datetimes to `datetime`; R keeps them as
  strings. The Python loader (`_OKFLoader`) drops the timestamp implicit
  resolver so both keep the authored string verbatim (and frontmatter stays
  JSON-serializable).
- **Content hash**: `sha1` of the body in both — R uses
  `digest(..., serialize = FALSE)`; Python uses `hashlib.sha1`. The body is
  normalized identically (Python's `splitlines()` matches R's `readLines()`:
  both strip the trailing newline and CR in CRLF), so `content_hash` matches
  across bindings. A conformance test (`content_hashes` in `expected/store.json`)
  locks this so it cannot regress.
- **`frontmatter` JSON** is semantically equal but **not** byte-identical across
  languages (key ordering/spacing differ); conformance asserts on parsed
  structure, not raw JSON bytes. So catalogs match on every column except the
  raw `frontmatter` text.
- **`n_concepts`** counts non-reserved concept documents; `index.md`/`log.md`
  are catalogued (`reserved = true`) but not counted as concepts (OKF: "all
  other `.md` files are concept documents").

## Roadmap

- ~~`okf_chunk` embeddings + vector search~~ — shipped (`embed` / `rag`).
- ~~An `okf` CLI in both languages~~ — shipped (`validate`/`ingest`/`query`/`context`/`html`/`embed`/`rag`).
- ~~git / tar / zip bundle readers~~ — shipped (`okf_fetch`).
- ~~Interactive graph view + community clustering + backlinks + incremental~~ —
  shipped (`graph`/`export`/`impact`, `okf_clusters`, `--incremental`).
- HTML render polish: optional sidebar nav, theme palettes (the `html` page
  itself stays minimal: no JS, inline CSS).
