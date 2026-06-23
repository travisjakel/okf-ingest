---
type: Concept
title: The OKF format
description: What an Open Knowledge Format bundle is — markdown + frontmatter, one concept per file, links as the graph.
timestamp: 2026-06-23T00:00:00Z
tags: [okf, spec]
---

# The OKF format

Open Knowledge Format (Google Cloud, v0.1) is a directory of markdown files with
YAML frontmatter: **one concept per file**, markdown links forming an explicit
graph. The only required field is `type`; `title`/`description`/`timestamp`/
`tags` are recommended. `index.md` and `log.md` are reserved (the map and the
history).

okf-ingest consumes that format — it reads exactly this structure into [the
catalog](catalog.md) and never adds to it ([determinism](determinism.md)). What
counts as [conformant](conformance.md) follows the spec permissively, and the
links become [the concept graph](links.md).
