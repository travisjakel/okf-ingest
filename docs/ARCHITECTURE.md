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
                          okf_link / okf_validation     ─┘
```

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

- `okf_chunk` embeddings + vector search (DuckDB-vss / sqlite-vec) — the
  "+queryable index" RAG layer.
- An `okf` CLI (`validate` / `ingest` / `query`) in both languages.
- git / tar / zip bundle readers (currently `dir`); `source_kind` already in the schema.
