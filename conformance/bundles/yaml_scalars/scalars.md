---
type: Attested Computation
title: "Bool-ish scalars"
description: "Locks YAML 1.2 core-schema boolean resolution across every binding."
tags: [conformance, yaml]
runtime: r
parameters:
  - { name: n, type: integer, required: true }
  - { name: y, type: integer, required: false }
  - { name: off, type: string, required: false }
  - { name: day, type: string, required: true }
generated: { by: okf-ingest/conformance, at: 2026-09-17T00:00:00Z }
status: stable
yes_word: yes
no_word: no
on_word: on
off_word: off
y_word: y
n_word: n
true_word: true
false_word: false
upper_true: TRUE
title_false: False
big_int: 835118974644
small_int: 42
negative_big: -835118974644
---

# Computation

```r
n + y
```

# Why this fixture exists

`y`, `Y`, `yes`, `n`, `N`, `no`, `on` and `off` are booleans in YAML **1.1** and
plain strings in YAML **1.2**. R's `yaml` and Python's PyYAML implement 1.1;
yaml-rust2, rapidyaml and the MATLAB subset parser do not. Before 0.12.1 the
three disagreed with each other -- `name: n` read as `FALSE` in R, `"n"` in
Rust, and PyYAML split the difference -- so a parameter named `n` could not be
bound at all in R.

All bindings now follow the 1.2 core schema: only `true` and `false` (and their
case variants) are booleans.
