---
type: Reference
title: Semantic search
description: The optional embed/rag layer — vector search over concept bodies via a local, pluggable embedder.
timestamp: 2026-06-23T00:00:00Z
tags: [rag, embeddings, search]
---

# Semantic search

The one part of okf that touches a model — and it is **opt-in, local, and
pluggable**. `okf embed` chunks concept bodies and stores embeddings in
`okf_chunk` (default embedder: local Ollama `nomic-embed-text`; swap in your
own). `okf rag` does brute-force cosine search via DuckDB's native
`list_cosine_similarity`.

For small, well-linked bundles you usually don't need this — the explicit graph
the author wrote beats fuzzy vector matches, and `okf context` (index-first
traversal) costs nothing. Reach for embed/rag on large or cross-corpus bases.
Re-embedding is [incremental](incremental.md). Note this is the documented
exception to [determinism](determinism.md): embedding output depends on the model.
