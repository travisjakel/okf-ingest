---
type: Index
title: okf-ingest
description: Map of the okf-ingest knowledge bundle — the project, documented as OKF.
timestamp: 2026-09-17T00:00:00Z
generated: { by: hand, at: 2026-09-17T00:00:00Z }
status: stable
tags: [okf, index]
---

# okf-ingest — self-describing bundle

okf-ingest documented *as an OKF bundle* — dogfood: this folder is a real,
conformant bundle you can ingest, render (`okf html` / `okf graph`), and check
(`okf doctor`) with the tool itself.

It is also written in **OKF v0.2**: every page carries `generated` and a SPEC
5.4 `status`, citations go through [references](references/index.md) rather
than reaching outside the bundle, and one figure the docs state is carried as an
[Attested Computation](computations/corpus-size.md) instead of as a sentence. A
package that implements the semantics should demonstrate them.

## Concepts

- [Determinism & no agents](determinism.md) — the core principle
- [The OKF format](okf-spec.md) — what a bundle is
- [The DuckDB catalog](catalog.md) — the interop contract
- [Conformance & parity](conformance.md) — how the five bindings stay identical
- [The five bindings](bindings.md) — thin, native, mirrored; two full, three core
- [Sources](sources.md) — dir, git, tar/zip
- [Validate](validate.md) — the conformance lint
- [The concept graph](links.md) — links, backlinks, impact
- [Query](query.md) — SQL and helpers over the catalog
- [Context](context.md) — the index-first LLM-wiki primitive
- [CLI](cli.md) — the command surface
- [Install](install.md) — PyPI, R-universe, dev
- [Rendering](render.md) — HTML site, interactive graph, Mermaid
- [Semantic search](search.md) — the optional embed/rag layer
- [Incremental](incremental.md) — re-ingest/re-embed only what changed
- [Doctor](doctor.md) — health & maintenance
- [Diff](diff.md) — drift & snapshot changelog
- [Rank](rank.md) — Personalized PageRank relevance (exact, deterministic)
- [Trust & lifecycle](trust.md) — the v0.2 provenance families, and what not to migrate
- [Attested Computations](computations.md) — SPEC 10: bind, run, prove

## This bundle's own v0.2 machinery

- [Computations](computations/index.md) — figures carried as contracts
- [References](references/index.md) — in-bundle stand-ins for outside sources
- [Run an R computation](skills/run-r.md) — the executor contract
- [Equality attester](attesters/equality.md) — provenance and fidelity

See [the change log](log.md) for history.
