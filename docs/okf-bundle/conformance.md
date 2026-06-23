---
type: Reference
title: Conformance & parity
description: How the R and Python bindings stay byte-identical, and what OKF conformance the tool enforces.
timestamp: 2026-06-23T00:00:00Z
tags: [conformance, parity, testing]
---

# Conformance & parity

A bundle is **conformant** iff every non-reserved `.md` has parseable YAML
frontmatter with a non-empty `type`. Everything else (missing recommended
fields, broken links, orphans, missing `index.md`) is a *finding*, never a
rejection — permissive per OKF v0.1.

The R and Python bindings are held to byte-identical [catalogs](catalog.md) by a
language-agnostic conformance suite (golden bundles + expected JSON), including a
`content_hash` parity lock and a hidden-directory guard. Both must skip dot-dirs
(`.git`/`.github`), sort files identically, and resolve links the same way. This
is what makes the [determinism](determinism.md) claim testable rather than
aspirational — and it's checked in CI alongside the [CLI](cli.md) smokes.
