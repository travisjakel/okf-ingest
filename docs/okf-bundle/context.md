---
type: Concept
title: Context
description: The index-first, link-following primitive — assemble a bundle slice for an LLM to read directly, no embeddings.
timestamp: 2026-06-23T00:00:00Z
tags: [context, llm, graph]
---

# Context

`okf context` is the faithful OKF / "LLM wiki" consume operation: hand an agent
`index.md` plus a concept and its link-neighborhood, assembled into one markdown
blob to read directly. It walks the [concept graph](links.md) you already built
to a depth, capped to a token budget — **no embeddings, no vector search**.

This is okf's answer to "let an LLM use my knowledge": [compose with the
agent](determinism.md), don't embed one. For small, curated bundles it beats
[semantic search](search.md) — the explicit links cost nothing and the author's
structure is better than fuzzy matches. See the [CLI](cli.md).
