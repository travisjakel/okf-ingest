---
type: Index
title: okf-ingest
description: Map of the okf-ingest knowledge bundle — the project, documented as OKF.
timestamp: 2026-06-23T00:00:00Z
tags: [okf, index]
---

# okf-ingest — self-describing bundle

okf-ingest documented *as an OKF bundle* — dogfood: this folder is a real,
conformant bundle you can ingest, render (`okf html` / `okf graph`), and check
(`okf doctor`) with the tool itself.

## Concepts

- [Determinism & no agents](determinism.md) — the core principle
- [The OKF format](okf-spec.md) — what a bundle is
- [The DuckDB catalog](catalog.md) — the interop contract
- [Conformance & parity](conformance.md) — how R and Python stay identical
- [The R & Python bindings](bindings.md) — thin, native, mirrored
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

See [the change log](log.md) for history.
