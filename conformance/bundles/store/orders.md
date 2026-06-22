---
type: BigQuery Table
title: "Orders"
description: "One row per customer order."
resource: bigquery://project/store/orders
tags: [sales, fact-table]
timestamp: 2026-06-20T12:00:00Z
---

# Orders

The orders fact table. Each order belongs to a [customer](/customers.md) and
contributes to [revenue](/metrics/revenue.md).
