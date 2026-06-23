---
type: Reference
title: Query
description: Read the catalog with SQL or the built-in helpers — concepts, links, findings, substring search.
timestamp: 2026-06-23T00:00:00Z
tags: [query, sql, duckdb]
---

# Query

Because the bundle lives in a [DuckDB catalog](catalog.md), you query it with
plain SQL — or the bare `duckdb` CLI, or from R/Python via the
[bindings](bindings.md). `okf query` wraps the common reads: `--sql`,
`--search <term>` (substring over bodies), `--concepts`, `--links`, `--findings`,
with `--json` output.

This is the "programmatic access" half of why okf-ingest exists: ask questions
of the [graph](links.md) and [validation findings](validate.md) from code or CI.
For meaning-based retrieval instead of substring/SQL, see [semantic
search](search.md); to hand a slice to an LLM, see [context](context.md).
