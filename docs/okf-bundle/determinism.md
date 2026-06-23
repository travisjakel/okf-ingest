---
type: Concept
title: Determinism & no agents
description: okf-ingest is pure deterministic machinery — same bundle in, same catalog/graph/render out, with no LLM agents.
timestamp: 2026-06-23T00:00:00Z
tags: [determinism, design]
---

# Determinism & no agents

The same bundle in always produces the same [catalog](catalog.md), the same
[graph](render.md), the same clusters, and the same rendered HTML out —
byte-for-byte, offline, no API key. **There are no LLM agents anywhere in the
core.** okf never asks a model to summarize, classify, or infer relationships;
it reads exactly the structure the author wrote (frontmatter + markdown links).

This is the deliberate line versus agent-based "understand my wiki" tools: their
output is non-reproducible, costs tokens, and invents structure. okf is the
reproducible substrate, and it *composes with* agents — hand the graph to your
model via [the CLI](cli.md)'s `context`, rather than pretending to be the model.

The two honest, opt-in exceptions: [semantic search](search.md) calls a local
pluggable embedding model, and the ingest timestamp is wall-clock (overridable).
Everything in [conformance & parity](conformance.md) is locked by tests.
