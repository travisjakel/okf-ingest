---
type: Runbook
title: Doctor
description: One-shot health/maintenance report with a score, CI exit codes, and opt-in safe auto-fixes.
timestamp: 2026-06-23T00:00:00Z
tags: [doctor, maintenance, health, ci]
---

# Doctor

Knowledge bases drift — links break when files move, timestamps go stale,
concepts orphan. `okf doctor` is a deterministic one-shot health scan over [the
catalog](catalog.md): it folds in the validation findings plus maintenance
checks (duplicate titles; future/stale timestamps with `--stale-days`) and
reports a health **score** = the percent of concepts with zero findings, with
CI-friendly exit codes (`--strict` fails on warnings too).

`okf doctor --fix` applies only *unambiguously-safe* repairs to source files —
normalize a parseable non-ISO `timestamp`, and re-point a broken link when
exactly one basename matches — and reports every change. Anything ambiguous is
reported, never guessed (consistent with [determinism](determinism.md); no LLM).

Wire it into CI or a pre-commit hook (see `examples/`) for ongoing maintenance.
It complements [incremental](incremental.md) re-ingest and the [CLI](cli.md).
