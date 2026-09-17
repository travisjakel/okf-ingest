---
type: Runbook
title: Diff
description: Deterministic concept-level changelog between two states of a bundle — drift since last ingest, or snapshot vs snapshot.
timestamp: 2026-06-26T00:00:00Z
generated: { by: hand, at: 2026-06-26T00:00:00Z }
status: stable
tags: [diff, drift, changelog, ci]
---

# Diff

`git diff` shows text hunks; `okf diff` shows what changed as *knowledge
structure*: concepts added / removed / changed (by `content_hash`), frontmatter
`type`/`title` changes, and [graph](links.md) deltas — edges added/removed,
links newly broken or fixed.

Each side can be a bundle directory or an ingested [catalog](catalog.md), so
one verb covers both shapes: `okf diff catalog.duckdb ./bundle` answers "what
drifted since the last ingest", and `okf diff old/ new/` is a changelog between
two snapshots.

Like [doctor](doctor.md) it is pure [deterministic](determinism.md) code — hash
and set comparison, output sorted by path, no model, no wall clock — and exits
`0` when identical, `1` when different, so it drops into CI as a change gate.
A conformance fixture locks every binding's output identical (see
[conformance](conformance.md)); complements [incremental](incremental.md),
which uses the same `content_hash` to skip unchanged work.
