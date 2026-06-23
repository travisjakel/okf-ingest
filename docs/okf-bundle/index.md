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
- [The DuckDB catalog](catalog.md) — the interop contract
- [Conformance & parity](conformance.md) — how R and Python stay identical
- [CLI](cli.md) — the command surface
- [Rendering](render.md) — HTML site, interactive graph, Mermaid
- [Semantic search](search.md) — the optional embed/rag layer
- [Incremental](incremental.md) — re-ingest/re-embed only what changed
- [Doctor](doctor.md) — health & maintenance

See [the change log](log.md) for history.
