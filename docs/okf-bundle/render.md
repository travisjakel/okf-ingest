---
type: Reference
title: Rendering
description: Turn a bundle into a navigable HTML site, an interactive force-directed graph, or a Mermaid diagram.
timestamp: 2026-06-23T00:00:00Z
tags: [html, graph, mermaid, viz]
---

# Rendering

Three views over the same [catalog](catalog.md), all self-contained (inline CSS,
no CDN):

- **`okf html`** — a navigable static site (one page per concept, links rewritten
  to page-relative `.html`) or a single self-contained file. Each page gets a
  metadata bar, a "Linked from" backlinks line, and a broken/orphan footer badge.
- **`okf graph`** — one interactive force-directed page (hand-rolled canvas JS, no
  framework): pan/zoom/drag, type-to-search, nodes coloured by OKF type with
  community clustering as fallback; click a node to open its page.
- **`okf export --mermaid`** — a Mermaid `graph LR` diagram for embedding in
  markdown; `okf export` alone emits portable `{nodes, edges}` JSON.

Rendering is [deterministic](determinism.md) — no model in the loop. See the
[CLI](cli.md) for invocation.
