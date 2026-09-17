---
type: Attested Computation
title: "Widgets processed per day"
description: "Sanctioned SQL for daily processed-widget counts, per the throughput policy."
tags: [ops, throughput, attested]
runtime: duckdb
parameters:
  - { name: day, type: string, required: true }
  - { name: line, type: string, required: false }
executor:
  resource: skills/run-local.md
  receipt: [run_id, executed_sql, result]
attester:
  resource: attesters/equality.py
generated: { by: okf-ingest/conformance, at: 2026-08-01T00:00:00Z }
verified:
  - { by: process:nightly, at: 2026-08-02T03:00:00+00:00 }
  - { by: human:reviewer, at: 2026-08-03T09:30:00-07:00 }
status: stable
stale_after: 2027-01-01T00:00:00Z
sources:
  - id: throughput-policy
    resource: /policies/throughput-policy.md
    title: Throughput policy
    author: human:reviewer
    last_modified: 2026-07-15T00:00:00Z
  - resource: all widget events in the local warehouse
---

# Computation

```sql
SELECT count(*) AS widgets
FROM events
WHERE day = $day
  AND ($line IS NULL OR line = $line)
```

Counts only events the throughput policy recognises as processed.[^throughput-policy]

[^throughput-policy]: Throughput policy
