---
type: Metric
title: "Throughput"
description: "Widgets processed per day."
tags: [ops, throughput]
resource: duckdb://local/metrics/throughput
generated: { by: okf-ingest/conformance, at: 2026-08-01T00:00:00+00:00 }
verified: { by: human:reviewer, at: 2026-08-03T09:30:00Z }
status: stable
sources:
  - id: throughput-policy
    resource: policies/throughput-policy.md
    title: Throughput policy
---

# Definition

Widgets processed per day, computed by
[the throughput computation](../computations/throughput.md), under the rules of
the throughput policy.[^throughput-policy]

[^throughput-policy]: Throughput policy
