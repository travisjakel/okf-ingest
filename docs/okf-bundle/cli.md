---
type: Reference
title: CLI
description: The okf command surface — identical verbs in R and Python.
timestamp: 2026-06-23T00:00:00Z
tags: [cli]
---

# CLI

Identical subcommands in both languages (`okf …` after a pip/R-universe install):

- `validate` — conformance lint (CI-friendly exit codes)
- `ingest` — load a bundle into [the catalog](catalog.md); `--incremental` (see [incremental](incremental.md))
- `query` — SQL / search / concepts / links / findings
- `context` — index-first, link-following blob for an LLM (no embeddings)
- `html` / `graph` / `export` — [rendering](render.md) and graph export (JSON or Mermaid)
- `impact` — inbound/outbound/transitive ripple of a concept
- `doctor` — [health & maintenance](doctor.md)
- `embed` / `rag` — [semantic search](search.md)

A `<source>` may be a directory, a git URL, or a tar/zip archive. All of it is
[deterministic](determinism.md) except the opt-in embedding calls.
