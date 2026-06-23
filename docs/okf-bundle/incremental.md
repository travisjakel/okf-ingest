---
type: Concept
title: Incremental
description: Re-ingest and re-embed only the concepts whose content changed, via content_hash fingerprints.
timestamp: 2026-06-23T00:00:00Z
tags: [incremental, maintenance]
---

# Incremental

Every concept row carries a `content_hash`. `okf ingest --incremental` diffs each
hash against a prior ingest into the same catalog and rewrites only
changed/added concepts (dropping removed ones); the summary reports
`changed`/`added`/`removed`/`cached`. Links and validation are always recomputed
(cheap, graph-global). A full ingest is an idempotent per-bundle replace.

`okf embed --incremental` re-embeds only concepts whose content changed — the
real win, since it skips the expensive [embedder](search.md) calls. Together they
make a large [catalog](catalog.md) cheap to keep current, which pairs with the
[doctor](doctor.md) maintenance gate. All hash comparison is
[deterministic](determinism.md).
