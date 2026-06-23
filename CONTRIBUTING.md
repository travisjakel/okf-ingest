# Contributing to okf-ingest

Thanks for your interest! okf-ingest is a small, deterministic tool with a strong
design line — contributions are welcome as long as they keep that line.

## The one rule: stay deterministic, no agents

The core must remain **pure and deterministic** — same bundle in, same catalog /
graph / clusters / render out — with **no LLM/agent calls**. The only place a
model is allowed is the opt-in `embed`/`rag` layer (a pluggable, local embedder).
No randomness (`random`/`uuid`/`sample`/`shuffle`), no wall-clock except the
overridable `ingested_at`. If a feature needs an LLM to decide something, it
belongs in a *caller* (hand it the graph via `okf context`), not in okf.

## The contract: `schema/` + `conformance/`

The cross-language interop contract is two language-neutral artifacts:

- `schema/catalog.sql` — the DuckDB catalog schema both bindings emit.
- `conformance/` — golden bundles + `expected/*.json` every binding must reproduce.

The R (`r/okf`) and Python (`py/okf`) bindings are thin and **held byte-identical**
by that corpus. A new binding (TS, Go, …) is conformant the moment it passes
`conformance/`.

## Working on a change

1. Make the change in **both** bindings (R and Python) — they mirror each other.
   Mirrored constants (e.g. `OKF_SCHEMA`, the HTML/graph templates) must stay in
   sync; the comment headers say where.
2. Run the conformance suites:
   ```bash
   Rscript conformance/check_r.R
   python  conformance/check_py.py
   ```
   Both must print `PASS`. If you change behavior that affects the catalog, update
   the golden `expected/*.json` deliberately (and explain why in the PR).
3. Add/extend a conformance fixture when you fix a cross-binding discrepancy, so
   it can't regress (e.g. the hidden-directory guard in `conformance/bundles/store`).
4. For R, keep `NAMESPACE` + `man/*.Rd` in step with exported functions
   (`R CMD INSTALL r/okf` should be clean).
5. CI runs both conformance suites plus CLI smokes (`validate`/`ingest`/`html`/
   `graph`/`doctor`/`--incremental`) on Linux/macOS/Windows.

## Dogfood

The project documents itself as an OKF bundle in [`docs/okf-bundle/`](docs/okf-bundle/)
— `okf validate docs/okf-bundle --strict` and `okf doctor docs/okf-bundle`
should stay clean (100/100). If your change touches behavior described there,
update the bundle too.

## Scope

okf-ingest is **consume-first** (validate / load / query / render / graph /
search / maintain). Authoring is intentionally out of scope for now — see the
Roadmap in the README. Open an issue before a large feature so we can check it
fits the deterministic, thin-bindings design.
