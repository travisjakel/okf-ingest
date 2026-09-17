---
type: Skill
title: Run an R computation
description: The executor contract for a runtime:r Attested Computation — what it must do and what the receipt must carry.
timestamp: 2026-09-17T00:00:00Z
generated: { by: hand, at: 2026-09-17T00:00:00Z }
status: stable
tags: [okf, attested, executor]
---

# Run an R computation

An executor for a `runtime: r` contract binds the declared parameters into the
computation, evaluates it, and returns a receipt.

It must:

1. **Bind from the contract, not from prose.** Expand the contract's own
   computation text with the supplied parameter values. The artifact that runs
   is derived, never authored by the caller.
2. **Refuse an un-allowlisted bundle.** Executing a computation is executing
   code; a reader of knowledge must opt in to that explicitly.
3. **Commit to the parameters.** Record a hash of the bound parameter set. For a
   runtime that binds by environment rather than by text expansion, the artifact
   is byte-identical whatever the parameters were, so without this the claimed
   parameters are unverified metadata.
4. **Return `run_id`, `executed_code`, `result`**, plus the contract path and
   start/finish instants.

The receipt is runtime evidence and is **not** part of the bundle. Keep it beside
the published artifact, where it documents one release.

See [Attested Computations](../computations.md).
