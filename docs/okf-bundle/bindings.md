---
type: Concept
title: The R & Python bindings
description: Two thin, native, mirrored bindings held byte-identical by the conformance corpus.
timestamp: 2026-06-23T00:00:00Z
tags: [r, python, bindings]
---

# The R & Python bindings

okf-ingest ships as two idiomatic packages — `r/okf` (R) and `py/okf` (Python) —
that mirror each other function-for-function. Neither is a wrapper around the
other; both are native, thin (~few hundred lines), and write the same
[catalog](catalog.md).

They are kept honest by [conformance & parity](conformance.md): a shared corpus
asserts byte-identical output, so you can [ingest](sources.md) in one and
[query](query.md) in the other. Mirrored constants (the schema, the
[render](render.md) templates) are kept in sync by hand, flagged in code
comments. This dual-binding design is why okf-ingest exists — there was no R or
Python OKF tooling. See [install](install.md).
