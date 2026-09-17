---
type: Attested Computation
title: "Open backlog"
description: "Sanctioned SQL for the open-backlog count, kept as a real file."
tags: [ops, backlog, attested]
runtime: duckdb
computation: computations/lib/backlog.sql
parameters:
  - { name: day, type: string, required: true }
executor:
  resource: skills/run-local.md
  receipt: [run_id, executed_sql, result]
attester:
  resource: attesters/equality.py
generated: { by: okf-ingest/conformance, at: 2026-08-01T00:00:00Z }
verified: { by: human:reviewer, at: 2026-08-03T09:30:00Z }
status: draft
sources:
  - id: missing-policy
    resource: policies/backlog-policy.md
    title: Backlog policy (not yet written)
---

# Notes

The computation lives in a file rather than a fence.[^missing-policy]

[^missing-policy]: Backlog policy (not yet written)
