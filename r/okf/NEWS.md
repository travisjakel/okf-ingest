# okf 0.12.1

* **Cross-binding parity fix: YAML 1.1 booleans.** `y`, `Y`, `yes`, `n`, `N`,
  `no`, `on` and `off` are booleans in YAML 1.1 and plain strings in YAML 1.2.
  R's `yaml` and Python's PyYAML implement 1.1; yaml-rust2, rapidyaml and the
  MATLAB subset parser do not. The three disagreed with each other on the same
  frontmatter -- `name: n` read as `FALSE` in R, `"n"` in Rust, and PyYAML split
  the difference -- which broke the promise that one bundle yields one catalog.
  In R the consequence was functional, not cosmetic: a parameter named `n` had a
  logical for a name and could never be bound by `okf_bind()`, and a parameter
  named `n` is entirely ordinary. Both 1.1 parsers now follow the YAML 1.2 core
  schema, so only `true`/`false` (and case variants) become logical and every
  other word stays the text the author wrote.

  Found by building a package on top of `okf_bind()` whose first test fixture
  happened to name a parameter `n`. The conformance corpus had no bool-ish
  scalar in it, so nothing caught it.

  Measured before shipping: across the 220 concepts of a live wiki and all four
  of the format's reference bundles, **zero** concepts' parsed frontmatter
  changes. The fix is inert on existing data and prevents the divergence.

* New fixture `bundles/yaml_scalars`, locked in all five bindings. It also
  records a pre-existing difference it would be dishonest to hide: R, Python and
  Rust are typed parsers and resolve `true` to a boolean, while the C++ and
  MATLAB parsers keep every scalar as raw text by design -- which is what makes
  timestamps verbatim for free there. The fixture asserts the 1.1-only words as
  strings in *every* binding, and asserts `true`/`false` per binding family.

# okf 0.12.0

Measured against the four reference bundles in
`GoogleCloudPlatform/open-knowledge-format`, which moved to its own repository
on 2026-08-14 (the copy under `knowledge-catalog/okf/` is retired). The spec is
still v0.2; what changed is that upstream now ships bundles exercising the v0.2
families, and running our own validator over them found two real defects.

* **`timestamp_not_iso8601` no longer false-fires.** SPEC 5 requires an ISO 8601
  datetime with an explicit UTC offset; upstream made that literal on 2026-08-21
  and the bundles now emit `+00:00`. The pattern demanded a trailing `Z`, so it
  flagged **44 of 44 concepts** across `ga4`, `stackoverflow` and
  `crypto_bitcoin`. It now accepts `Z`, `+/-HH:MM` and `+/-HHMM` with optional
  fractional seconds, and still rejects a bare local datetime. All four upstream
  bundles now validate with zero findings.
* **The path-valued frontmatter fields of SPEC 6.2 are graph edges.**
  `resource`, `sources[].resource`, `computation`, `executor.resource` and
  `attester.resource` carry the derivation and execution edges and appear
  nowhere in the body. On `acme_retail` that is 12 edges against 30 body edges;
  before this, `okf_impact("policies/revenue-recognition.md")` returned a single
  inbound edge — the policy's own directory index — while both Attested
  Computations and both Metrics deriving from it were invisible. It now returns
  all six. `okf_rank`, `okf_context`, `okf_backlinks` and the orphan lint all
  inherit the fix.
* **`okf_link` gains `kind` and `target`.** `kind` is
  `body`/`wikilink`/`resource`/`source`/`computation`/`executor`/`attester`;
  `target` is `concept` (the only case that forms a graph edge), `file` (a real
  non-concept file in the bundle), `scope` (a SPEC 5.1 scope descriptor, not a
  path) or `missing`. A reference to a real non-concept file — an attester
  `.py`, a computation `.sql`, exactly what SPEC 6.2/6.3 describe — was reported
  as a broken link; it is now an `info`-level `non_concept_target`, and
  `links_broken` counts only genuinely missing targets. An unresolved
  frontmatter path is `broken_reference` rather than `broken_link`.
* **New `info` severity.** It is neither an error nor a warning and never enters
  the warning count. (Two bindings had to be corrected for this: the C++ and
  MATLAB summaries counted everything non-error as a warning.)
* **Root-relative frontmatter paths are accepted, and reported.** SPEC 6.2 says
  a bundle-relative path begins with `/`, but upstream's own bundles write them
  without it: **12 of 12** frontmatter paths in `acme_retail` resolve against
  the bundle root and **0 of 12** resolve the spec-literal way, so a
  spec-literal consumer finds none of these edges. Resolution tries the spec
  reading first, falls back to the root, and emits `path_root_relative` (info)
  when the fallback is what worked — permissive per SPEC 11, and legible to a
  producer. The bundles and the spec disagree here; worth an upstream issue.
* New conformance fixture `bundles/v02_attested` (ours, not vendored, so we do
  not track upstream churn), locked in all five bindings. It covers both
  computation forms (inline `# Computation` fence and `computation:` by path),
  every frontmatter edge kind, a non-concept target, a scope descriptor, a
  genuinely missing reference, `verified` as a bare mapping *and* as a list,
  `status` draft/stable/deprecated, `stale_after`, and offset timestamps in
  `Z` / `+00:00` / `-07:00` form.
* MATLAB: the YAML-subset parser now handles a block sequence whose items are
  **flow maps** (`- { name: day, type: string, required: true }`). This is not
  an edge case: it is the shape SPEC 10.2 uses for `parameters:` and the one
  upstream's `acme_retail` writes, so the binding previously could not read a
  real Attested Computation's parameters.
* `okf_ollama_embedder()` resolves its endpoint from the environment
  (`url=` / `LLM_EMBED_URL` / `LLM_LOCAL_BACKEND=llamaswap` / `OLLAMA_URL`) and
  speaks whichever of the Ollama or OpenAI embedding shapes the resolved path
  implies, mirroring `okf.rag._embed_endpoint`. A host that names `OLLAMA_URL`
  is unaffected; `options(okf.embed_texts=)` overrides with a custom backend.
* `bin/okf.R` refuses to run when an installed `okf` differs in version from
  the source tree the script lives in, instead of silently preferring the
  installed package. Set `OKF_ALLOW_VERSION_MISMATCH=1` to override.
* Docs: the spec links point at the new repository; the four surfaces still
  claiming v0.1 conformance now say v0.2.
* **New: the v0.2 semantics, R and Python only.** `okf_trust()` derives SPEC 5.3
  trust tiers and SPEC 5.5 staleness from the absolute `stale_after` instant,
  superseding the home-grown `stale_days` age heuristic. `okf_sources()` reads
  SPEC 5.1 provenance one row per entry, including the footnote-label join into
  `sources[].id`; it records the spec's signals and, like the spec, refuses to
  compute a credibility score. `okf_computations()` reads SPEC 10 Attested
  Computation contracts, and `okf_bind()` performs the deterministic parameter
  binding plus a canonical sha1 -- SPEC 10.3 makes the attester's job "re-derive
  the same binding and compare", so the binder belongs in the deterministic
  layer. R and Python produce identical binding hashes. Nothing here executes or
  attests anything.
* Ten new `okf_doctor()` rules over those families, each negative-tested before
  being believed. The catalog gains trust/lifecycle columns on `okf_concept`
  plus `okf_source` and `okf_computation` tables; the catalog-free bindings are
  unaffected.
* **Producer extensions are not misread.** `status` is a closed vocabulary in
  SPEC 5.4 and a producer extension everywhere else. Values outside the spec
  vocabulary are treated as ABSENT, never mapped, and reported as `info`
  (`status_not_spec_vocabulary`), as is a family key carrying the wrong shape
  entirely (`family_not_spec_shape`). Measured on a 220-concept wiki that writes
  `status: active` and `sources: 3`: zero concepts relabelled, zero new
  warn/error findings. That wiki also proved the need for shape checks before
  indexing -- `$` on an atomic vector is a hard error in R, and one such concept
  aborted the ingest of the whole bundle.
* `okf_context()` annotates each included concept with its lifecycle state
  (deprecated / draft / stale / unverified) when `now` is supplied. Annotated,
  never demoted or dropped: SPEC 11 says surface rather than silently drop, and
  a deprecated concept is still a legitimate link target, so demoting it would
  trade measurable retrieval recall for a warning the reader can be handed for
  free. Selection is unchanged, verified.
* New CLI verbs `okf trust` and `okf computations`, identical in R and Python.
* Retrieval was measured, not assumed, on the LOLO bench: the frontmatter edges
  leave `wiki` and `interpretable_ml_wiki` bit-identical (neither uses v0.2 path
  fields, so the graphs are unchanged at 713 and 278 edges), and on upstream's
  `acme_retail` they take the graph 29 -> 39 edges with every method improving
  (query-ppr R@5 .689 -> .835, MRR .653 -> .854; the eval set also grows 6 -> 8
  pages, so read the direction rather than the decimal).

# okf 0.11.0

* OKF spec v0.2 core support, in all five bindings: the concept `timestamp`
  (and catalog column) now falls back to v0.2's `generated: {by, at}` when
  the legacy field is absent (spec section 13), so pure-v0.2 bundles no longer
  draw spurious `missing_timestamp` warnings; the new `sources` / `verified` /
  `usage_window` / `status` / `stale_after` families parse and are preserved
  verbatim in `frontmatter`. New conformance fixture `bundles/v02` locks the
  fallback and the parsed shapes cross-binding.
* MATLAB: the verbatim YAML-subset parser now covers v0.2's nested shapes —
  flow maps (`generated: { by, at }`), one-level block maps, and block
  sequences of maps (`sources:`) — previously these raised
  `yaml_parse_error`, making v0.2 bundles read non-conformant under the
  MATLAB binding only. Deeper nesting still errors (spec-sanctioned).
* Docs: SPEC_NOTES rewritten for v0.2 (what is implemented, what is
  deliberately skipped: legacy `# Citations` parsing, trust-tier surfaces).
  v0.1 bundles remain fully supported; hard conformance rules are unchanged.

# okf 0.10.0

* New Rust binding (`rust/okf-ingest`, crates.io `okf-ingest`): the
  fixture-locked core — parse + `content_hash`, links/wikilinks, validate,
  ingest summary, exact PPR + lexical seeds + query cascade, diff (incl. drift
  mode), fetch (dir/tar/zip/git) — as a pure-Rust crate, conformance-gated in
  CI alongside R and Python (`conformance/check_rust.sh`). Catalog-free by
  design: every conformance-asserted value is computed in memory, which also
  documents that DuckDB is an access mechanism of the R/Python checkers, not
  part of the behavioral contract. No html/doctor/RAG/CLI in Rust.
* New C++ binding (`cpp/`, C++17 static library, CMake + FetchContent:
  rapidyaml + nlohmann/json + vendored SHA-1): the same fixture-locked core,
  conformance-gated in CI (`conformance/check_cpp.sh`, ctest on ubuntu +
  windows/MSVC). Fetch is descoped to dir / local tar (system `tar`) / git;
  zip and remote archives stay R/Python-only. Float parity pinned by
  `-ffp-contract=off` / `/fp:precise`.
* New MATLAB binding (`matlab/+okf`, pure MATLAB, Octave-compatible, zero
  toolboxes): the same fixture-locked core, conformance-gated in CI on real
  MATLAB (`conformance/check_matlab.sh`, matlab-actions). Ships a verbatim
  YAML-subset parser and a pure-M SHA-1; PPR rounding uses sprintf-based
  half-even (MATLAB `round()` is half-away-from-zero). Fetch covers
  dir / tar / zip / git with a post-extraction containment check.

# okf 0.9.0

* Query-seeded retrieval: new `okf_seeds()` (deterministic lexical seed
  selection — +3 title / +2 description·tags / +1 body per query token, fixed
  stopword list) and multi-seed `okf_rank()` (`start` may be a vector, with
  `weights`). `okf_context(query = "...")` chains them: lexical seeds ->
  multi-seed Personalized PageRank -> relevance-filled context. Deterministic
  hybrid retrieval with no embeddings; CLI `context --query`.
* `okf_doctor()` gains `duplicate_identity` (the same normalized id/alias
  claimed by more than one concept — breaks by-name resolution) and
  `hub_concentration` (info severity: pages whose outbound links mostly point
  at high in-degree hubs). New `info` severity never affects the health score
  (`n_info` added).
* Protected pages: concepts with `reviewed: true` in frontmatter are never
  modified by `okf_doctor_fix()` — human-validated content stays put.
* New conformance fixture locks query seeding + multi-seed PPR across R and
  Python.

# okf 0.8.0

* New `okf_rank()`: Personalized PageRank relevance scores over the concept
  graph, seeded on a start concept — exact power iteration (deterministic, no
  sampling, no embeddings), undirected resolved-link graph, teleport and
  dangling mass returning to the seed. New CLI verb `rank`.
* `okf_context(rank = "ppr")`: budget-fill the context blob by PPR relevance
  instead of BFS discovery order, so hub-heavy bundles surface the pages that
  matter to the topic first. Default behavior unchanged (`rank = "bfs"`).
* Cross-language parity: a new conformance fixture locks R and Python PPR
  scores byte-identical (10 decimals).

# okf 0.7.0

* New `okf_diff()`: deterministic concept-level changelog between two states
  of a bundle. Each side can be a bundle directory, an `okf_read()` bundle, a
  DuckDB catalog path, or an open connection — so it covers both "what drifted
  since the last ingest" (catalog vs directory) and snapshot-vs-snapshot
  comparison. Reports concepts added/removed/changed (by `content_hash`),
  frontmatter `type`/`title` changes, and link-graph deltas (edges
  added/removed, links newly broken or fixed).
* CLI: new `diff` verb (`okf diff <a> <b> [--json]`), exit 0 when identical /
  1 when different, for use as a CI change gate.

# okf 0.6.0

* `[[wikilink]]` support: `[[target]]` / `[[target|display]]` references are
  resolved by name — `id`, then `aliases`, then `title`, then filename stem —
  making Obsidian/Logseq/Foam-style vaults ingestible. Ambiguous names resolve
  to nothing (deterministic) rather than guessing. Markdown `](path)` links
  are unchanged.
* New `okf_extract_wikilinks()`; `okf_links()` now returns both link kinds.

# okf 0.5.2

* First CRAN release. Read, validate, and load OKF bundles into a portable
  DuckDB catalog; concept graph (`okf_links()`, `okf_backlinks()`,
  `okf_impact()`, `okf_clusters()`); HTML rendering (`okf_html()`,
  `okf_graph_html()`, Mermaid export); index-first context assembly
  (`okf_context()`); health checks (`okf_doctor()`, `okf_doctor_fix()`);
  incremental re-ingest/re-embed; optional local-embedder semantic search
  (`okf_embed()`, `okf_rag()`).
