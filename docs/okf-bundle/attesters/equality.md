---
type: Attester
title: Equality attester
description: Re-derives the binding from the contract and the receipt's own parameters, then compares — provenance and fidelity, deterministically.
timestamp: 2026-09-17T00:00:00Z
generated: { by: hand, at: 2026-09-17T00:00:00Z }
status: stable
tags: [okf, attested, attester]
---

# Equality attester

Two checks, and a verdict that consults no model.

**Provenance** — re-derive the binding from the *contract* and the receipt's own
parameters, canonicalise both sides, compare. The attester does not take the
receipt's word for what should have run: it recomputes it, so a rewritten
expression, a swapped computation file and a mutated parameter all fail the same
way.

**Fidelity** — compare the value about to be displayed against the receipt's
own result. A check that does only provenance passes a run that computed the
right thing and then reported a different number.

Staleness **warns**, and never sets the verdict: a definition past its
`stale_after` can still attest cleanly, and whether that should block a release
is a policy call, not an arithmetic one.

What it cannot do: prove the contract is the one anybody sanctioned. Edit the
computation and both sides of the comparison move together. That is
[`verified`](../trust.md)'s job, or a pinned hash of the contract's canonical
text.
