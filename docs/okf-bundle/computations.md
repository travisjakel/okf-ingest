---
type: Concept
title: Attested Computations
description: SPEC 10 — a figure a document states can be bound to parameters, executed, and proved to be the number that ran.
timestamp: 2026-09-17T00:00:00Z
generated: { by: hand, at: 2026-09-17T00:00:00Z }
status: stable
sources:
  - id: okf-spec-s10
    resource: https://github.com/google/open-knowledge-format
    title: OKF v0.2, section 10
  - id: bind-r
    resource: references/r-binding.md
    title: okf_computations / okf_bind / okf_canonicalize (R)
  - id: fixture
    resource: references/conformance-corpus.md
    title: The conformance fixture for attested computations
tags: [okf, attestation, computation, v0.2]
---

# Attested Computations

A document that states a number is asking to be believed. SPEC 10[^okf-spec-s10] lets it carry
the computation instead: a typed parameter list, a runtime, and the expression
itself, so a consumer can bind, run, and check rather than trust.

okf-ingest supplies the reading half and the binding[^bind-r]:

- `okf_computations(rd)` — every concept carrying a `# Computation` block, with
  its `parameters`, `runtime`, `executor`, `attester` and `stale_after`.
- `okf_bind(contract, params)` — expands the contract with a set of parameter
  values and returns the canonical artifact plus its hash. **This is the
  keystone.** Attestation compares the artifact that ran against the contract
  re-bound from the receipt's own parameters, so a rewritten expression, a
  swapped computation file and a mutated parameter all fail the same check.
- `okf_canonicalize(text)` — the normalisation both sides of that comparison go
  through, so whitespace is not evidence.

The shape is locked by a conformance fixture[^fixture].

Running and attesting is deliberately *not* here: a reader of knowledge should
not execute code as a side effect of reading. That half lives in a separate
runtime package.

## What attestation does not prove

It proves a run matches its contract. It cannot prove the contract is the one
anybody sanctioned — edit the computation in the bundle and both sides of the
comparison move together, so the run still attests cleanly. SPEC 10.6 draws the
same line from the other direction: `verified` (SPEC 5.2) confirms the
*definition* still matches policy and is doc-level and slow; attestation
confirms a single *run* and is per-call. Both exist because neither implies the
other.

The mechanical half of the first one is to hash the contract's canonical text
and have the caller pin it. Then changing the formula takes two deliberate
steps instead of one silent one — which is the point.

See [trust & lifecycle](trust.md) for the doc-level families, and
[determinism](determinism.md) for why none of this consults a model.

[^okf-spec-s10]: OKF v0.2, section 10
[^bind-r]: okf_computations / okf_bind / okf_canonicalize (R)
[^fixture]: The conformance fixture for attested computations
