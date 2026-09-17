---
type: Attested Computation
title: "Fenced code is not a link"
description: "Locks that references inside fenced code blocks are not extracted."
tags: [conformance, links]
runtime: r
parameters:
  - { name: src, type: "string", required: true }
generated: { by: okf-ingest/conformance, at: 2026-09-17T00:00:00Z }
status: stable
---

# Fenced code is not a link

A real markdown link to [Target](target.md), and a real [[Target]] wikilink,
both outside any fence. Both must be extracted.

# Computation

```r
# Every reference below is CODE, not a link, and must not be extracted.
# R's [[ ]] indexing is literally the wikilink syntax, which is why an
# Attested Computation with runtime: r hits this immediately.
flat[[paste0("knock_on_", src)]] <- 1
other <- lst[[src]]
collide <- lst[[target]]
cat("[phantom](target.md)")
```

A tilde fence behaves the same way:

~~~
[phantom-tilde](target.md)
[[target]]
~~~

Indented four spaces is NOT masked, because that is also ordinary nested-list
continuation:

- outer item
    - [Target](target.md) here is a real link

Inline code spans are NOT masked either, and that is a measured decision rather
than an oversight. Authors use backticks around a reference for emphasis and
mean it: in a 219-concept wiki, masking inline spans would have dropped **8
real, resolving edges** written with backticks around a double-bracket
reference. So `[[Target]]` in a span below is still extracted, and a
code-shaped reference in prose is the author's problem to quote differently.

A span that still counts as a reference: `[[Target]]`.
