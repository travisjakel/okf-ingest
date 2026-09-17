## Update: 0.7.0 -> 0.12.0

Second update; consolidates five additive releases (see NEWS.md):

* 0.8.0 — `okf_rank()`: Personalized PageRank relevance over the concept
  graph, computed by exact power iteration (deterministic); `okf_context()`
  gains `rank = "ppr"` for relevance-weighted context assembly.
* 0.9.0 — `okf_seeds()` + multi-seed ranking: `okf_context(query = ...)`
  serves free-text queries via deterministic lexical seeding; `okf_doctor()`
  gains duplicate-identity and (info-severity) hub-concentration checks;
  `reviewed: true` pages are protected from `okf_doctor_fix()`.
* 0.10.0 — no R code changes: version kept in lockstep with the repository's
  new Rust, C++, and MATLAB bindings (all held byte-identical to the R
  binding by the shared conformance corpus).
* 0.11.0 — OKF spec v0.2 support: the concept `timestamp` falls back to the
  new `generated: {by, at}` frontmatter when the legacy field is absent;
  new v0.2 field families parse and are preserved. Backward compatible;
  v0.1 bundles unchanged.
* 0.12.0 — conformance fixes measured against the reference bundles published
  by the format's maintainers, plus the v0.2 semantics those bundles exercise:
  timestamps with an explicit UTC offset (previously only a trailing `Z` was
  accepted, which mis-flagged conformant input); the specification's
  path-valued frontmatter fields now contribute graph edges; new exported
  readers `okf_trust()`, `okf_sources()`, `okf_computations()`, `okf_bind()`,
  `okf_canonicalize()` and `okf_resolve_path()`; new `okf_doctor()` rules over
  the same families. Additive; existing outputs gain columns but no existing
  column changes meaning.

No API changes or removals; all additive and offline (no new dependencies).

## R CMD check results

0 errors | 0 warnings | 1 note

* The only NOTE is "Days since last update" — the releases are additive and
  were completed together; consolidated here into one submission.

## Test environments

- Windows 11, R 4.5.0 (local)
- GitHub Actions: ubuntu-latest, macos-latest, windows-latest (R release)

## Notes

* The package optionally talks to a local Ollama server for embeddings
  (`okf_ollama_embedder`/`okf_embed`/`okf_rag`) and can fetch remote bundles
  (git/tar/zip) in `okf_fetch`; none of this runs during checks, examples, or
  tests — all tests use a small inline bundle in `tempdir()` and no network.
* `commonmark` (HTML rendering) and `httr2` (embeddings) are Suggests, guarded
  with `requireNamespace()`.
* There are no reverse dependencies.
