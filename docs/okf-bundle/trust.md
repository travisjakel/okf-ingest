---
type: Concept
title: Trust & lifecycle
description: The OKF v0.2 frontmatter families — generated, verified, sources, status, stale_after — and what a conforming consumer does with them.
timestamp: 2026-09-17T00:00:00Z
generated: { by: hand, at: 2026-09-17T00:00:00Z }
status: stable
stale_after: 2027-09-17T00:00:00Z
sources:
  - id: okf-spec-v02
    resource: https://github.com/google/open-knowledge-format
    title: OKF v0.2, sections 5 and 6
  - id: trust-r
    resource: references/r-binding.md
    title: okf_trust / okf_sources / okf_computations (R)
  - id: trust-py
    resource: references/py-binding.md
    title: The Python mirror
tags: [okf, trust, provenance, lifecycle, v0.2]
---

# Trust & lifecycle

OKF v0.2[^okf-spec-v02] adds five frontmatter families that say where a concept came from and
whether it can still be believed. `okf_trust()`[^trust-r] reads them; `okf_sources()`
flattens the citations; [doctor](doctor.md) rules them. The Python binding
mirrors all three[^trust-py].

| field | shape | means |
|---|---|---|
| `generated` | `{ by, at }` | which process produced this page, and when |
| `verified` | `{ by, at }` | who last confirmed the content still holds |
| `sources` | sequence of maps with `resource` | what it was derived from |
| `status` | `draft` / `stable` / `deprecated` | SPEC 5.4's closed vocabulary |
| `stale_after` | an ISO-8601 instant | past this, re-verify before serving |

## Permissive by design, and that is the trap

A value that is not in the declared shape is **treated as absent**, not as an
error. `status: archived` is read as no status at all; `sources: 3` is read as
no sources. That is the spec-correct behaviour and it is also silent, so
`okf doctor` reports both at `info` severity with the message "treated as
absent" rather than letting them pass unremarked.

The expensive version of this is a *producer extension that occupies a family
name*. A corpus writing `sources: 3` as a count is not merely unconformant — it
can never use `sources` for what v0.2 means by it while the name is taken. Two
bundles in the authoring estate had exactly this and had to be renamed
(`n_sources:`, `verification_method:`) before they could record any real
provenance.

## What NOT to migrate

v0.1's bare `timestamp` is still valid: the v0.2 reference bundle keeps it and
says a v0.2 consumer reads it unchanged. It is not a deprecated spelling of
`generated.at`, because `generated` says *which agent produced the page* —
true for a rendered corpus, an invention for a hand-written one. Adding it
where no producer exists manufactures provenance, which is worse than having
none.

`stale_after` is an absolute instant (SPEC 5.5), so staleness is a plain
comparison with no reference to when the concept was read. A bare date does not
qualify.

See [Attested Computations](computations.md) for the per-run half of the same
idea, and [validate](validate.md) for the hard rules that sit under all of this.

[^okf-spec-v02]: OKF v0.2, sections 5 and 6
[^trust-r]: okf_trust / okf_sources / okf_computations (R)
[^trust-py]: The Python mirror
