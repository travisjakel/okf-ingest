---
type: Concept
title: The concept graph
description: Markdown links become resolved/broken edges — surfaced as backlinks, impact, clusters, and the graph view.
timestamp: 2026-06-23T00:00:00Z
tags: [graph, links, backlinks]
---

# The concept graph

Every markdown link is resolved against the bundle and stored in `okf_link` as a
resolved or broken edge (consumers must tolerate broken links per
[the spec](okf-spec.md)). That graph is the heart of the [catalog](catalog.md).

Deterministic helpers surface it: `backlinks` ("linked from"), `impact`
(inbound/outbound/transitive ripple of a concept), and `clusters` (communities
via reproducible label propagation). The same graph drives [rendering](render.md)
— the interactive graph view and Mermaid export — and the [context](context.md)
primitive. No relationships are inferred ([determinism](determinism.md)); only
the links you wrote.
