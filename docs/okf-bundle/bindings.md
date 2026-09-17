---
type: Concept
title: The five bindings
description: Five native, mirrored bindings held byte-identical by one conformance corpus — two carry the full surface, three carry the core.
timestamp: 2026-09-17T00:00:00Z
generated: { by: hand, at: 2026-09-17T00:00:00Z }
status: stable
sources:
  - id: r-binding
    resource: references/r-binding.md
    title: The R binding
  - id: py-binding
    resource: references/py-binding.md
    title: The Python binding
  - id: conformance-corpus
    resource: references/conformance-corpus.md
    title: The shared conformance corpus and its five checkers
tags: [r, python, rust, cpp, matlab, bindings]
---

# The five bindings

okf-ingest ships as five native packages that mirror each other. None is a
wrapper around another; each is idiomatic in its own language, thin, and writes
the same [catalog](catalog.md).

They split into two tiers, and the split is deliberate rather than aspirational:

**Full surface** — `r/okf`[^r-binding] and `py/okf`[^py-binding]. Read, validate, ingest, the concept
[graph](links.md), [query](query.md), [context](context.md), [rank](rank.md),
[diff](diff.md), [doctor](doctor.md), plus the v0.2 [trust families](trust.md)
and [Attested Computations](computations.md).

**Core only** — `rust/okf-ingest`, `cpp/okf`, `matlab/+okf`. Parse, links,
validate, ingest, diff, graph. Enough to read a bundle and write a conformant
catalog from a language that has no other route to one.

## Why the core tier is not a lesser tier

The three core bindings have caught defects the two full ones did not, because
they parse differently. R, Python and Rust use typed YAML parsers; C++ uses
rapidyaml and MATLAB a hand-rolled reader. A change that all three typed
parsers agree on can still be wrong, and the two raw-text readers are the ones
that say so — a new `info` severity broke only the C++ and MATLAB checkers,
because they were the only ones counting every non-error as a warning.

## What keeps them identical

One [conformance corpus](conformance.md)[^conformance-corpus]: nine bundles and ten expected-output
fixtures, checked by `check_r.R`, `check_py.py`, `check_rust.sh`, `check_cpp.sh`
and `check_matlab.sh`. The assertion is byte-identical output, so you can
[ingest](sources.md) in one language and [query](query.md) in another.

The corpus is also the thing that cannot find a defect on its own. Every
cross-binding break fixed in 0.12.x — frontmatter paths as graph edges, YAML 1.1
booleans, links extracted from inside code fences, 32-bit integer coercion — was
found by running the bindings over *real* bundles, not fixtures. The corpus
agreed with itself in all four cases; only unfamiliar input disagreed. Each one
became a fixture afterwards, which is what a corpus is for: it locks a defect
out, it does not find it.

Mirrored constants (the schema, the [render](render.md) templates) are kept in
sync by hand and flagged in code comments. See [install](install.md).

[^r-binding]: The R binding
[^py-binding]: The Python binding
[^conformance-corpus]: The shared conformance corpus and its five checkers
