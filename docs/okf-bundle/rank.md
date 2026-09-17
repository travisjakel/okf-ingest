---
type: Runbook
title: Rank
description: Personalized PageRank relevance over the concept graph — exact power iteration, deterministic, no embeddings; powers relevance-weighted context.
timestamp: 2026-07-02T00:00:00Z
generated: { by: hand, at: 2026-07-02T00:00:00Z }
status: stable
tags: [rank, pagerank, retrieval, graph]
---

# Rank

`okf rank` scores every concept's relevance to a start concept with
**Personalized PageRank** over the [concept graph](links.md) — the author's
own link structure, no embeddings, no model. Where PPR is usually approximated
with Monte-Carlo walks, here it is computed by *exact power iteration*, so it
is [deterministic](determinism.md) like everything else: a
[conformance](conformance.md) fixture locks the bindings to
byte-identical scores.

The walk runs on the undirected resolved-link graph (a page and its citers are
mutually relevant, as in [links](links.md)); teleport and dangling mass return
to the seed. [Context](context.md) consumes it via `--rank ppr`: the token
budget fills by relevance instead of BFS discovery order, so hub-heavy bundles
surface the pages that matter to the topic first.

Multi-seed personalization serves free-text queries: `context --query`
picks seeds lexically (title > description/tags > body), then ranks the
graph from all seeds at once — the deterministic answer to hybrid retrieval.
