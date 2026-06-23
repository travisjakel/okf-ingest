---
type: Reference
title: The DuckDB catalog
description: The portable, SQL-queryable catalog that both bindings write — the cross-language interop contract.
timestamp: 2026-06-23T00:00:00Z
tags: [duckdb, schema, catalog]
---

# The DuckDB catalog

Ingesting a bundle loads it into a portable DuckDB catalog: `okf_bundle`,
`okf_concept` (one row per file, keyed by `(bundle_id, path)`), `okf_link` (the
resolved/broken graph edges), `okf_validation` (findings), and `okf_chunk`
(optional embeddings + each concept's `content_hash`).

The schema *is* the interop contract — see [conformance & parity](conformance.md).
Query it with SQL, the bare `duckdb` CLI, R, or Python. It powers
[rendering](render.md), [semantic search](search.md), [incremental](incremental.md)
re-runs, and [doctor](doctor.md). The whole thing is [deterministic](determinism.md).
