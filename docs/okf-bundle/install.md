---
type: Reference
title: Install
description: Get okf-ingest from PyPI (Python) or R-universe (R), or run from a clone.
timestamp: 2026-06-23T00:00:00Z
tags: [install, pypi, r-universe]
---

# Install

- **Python:** `pip install okf-ingest` (adds the `okf` command + importable
  package). Optional extras: `okf-ingest[html]` for [rendering](render.md).
- **R:** `install.packages("okf")` from R-universe, or `R CMD INSTALL r/okf`
  from a clone.
- **Dev / no install:** `source("r/okf/R/okf.R")` in R, or
  `PYTHONPATH=py python -m okf …` for the Python [CLI](cli.md).

Both [bindings](bindings.md) are intentionally light on dependencies (yaml +
DuckDB at the core; an embedder and a markdown engine are optional). Once
installed, point it at any [source](sources.md).
