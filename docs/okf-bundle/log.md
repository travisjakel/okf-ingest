---
type: Log
title: Change log
description: Chronological history of the okf-ingest self-bundle.
timestamp: 2026-06-23T00:00:00Z
generated: { by: hand, at: 2026-06-23T00:00:00Z }
tags: [log]
---

# Change log

- **2026-09-18** 0.13.0 — [`.okfignore`](ignore.md). SPEC 3.1 reserves two
  filenames and calls every other `.md` file a concept, so a bundle had no way
  to say that its README or its `schema.md` was scaffolding — each one failed
  the hard `type:` rule, and a conformant bundle was unreachable for any
  repository that is also a repository. An ignored file leaves the concept set
  and stays in the file set, so a reference to it resolves as
  `non_concept_target` rather than breaking, and the catalog schema is
  unchanged. The grammar is a small, fully specified subset of gitignore with
  one file at the bundle root and no cascade, locked across all five bindings
  by `bundles/okfignore`. The count of ignored files is reported by `okf
  validate`, because an ignored file produces no findings at all and an
  over-broad pattern would otherwise read as a bundle that got healthier
  instead of one that got smaller.

- **2026-09-17** 0.12.3 — the self-bundle catches up, and is rewritten in
  **OKF v0.2**. It had documented a two-binding, pre-trust package since June
  while the package grew to five bindings, the SPEC 5 trust families and SPEC 10
  Attested Computations. New: [trust & lifecycle](trust.md),
  [Attested Computations](computations.md), and one real contract
  ([conformance corpus size](computations/corpus-size.md)) so a number the docs
  state is executable rather than merely written down. Every page carries
  `generated` and a SPEC 5.4 `status`; citations go through
  [references](references/index.md), because a `sources[].resource` that points
  at `../../r/okf` names something real and still reads as a broken reference to
  anyone who fetched this bundle alone. `generated.at` is each page's own
  recorded `timestamp`, not the date the field was added — stamping today on a
  page written in June would manufacture the provenance the field exists to
  record.
- **2026-06-23** Creation — okf-ingest documents itself as an OKF bundle
  (dogfood): determinism, the OKF format, catalog, conformance, bindings,
  sources, validate, the concept graph, query, context, cli, install, render,
  search, incremental, doctor. Rendered by `okf html`/`okf graph` (the README
  hero); gated by `okf doctor` (100/100) in CI.
- **2026-06-26** 0.7.0 — `okf diff`: deterministic concept-level changelog
  between two bundle states (drift vs catalog, or snapshot vs snapshot); new
  conformance fixture locks R/Python parity. Prompted by reviewing
  matrixorigin/Memoria's `memory_diff` — the one idea there with a clean
  file-native analog.
- **2026-07-02** 0.8.0 — `okf rank`: exact power-iteration Personalized
  PageRank over the concept graph (deterministic, parity-locked); `context
  --rank ppr` budget-fills by relevance. Idea credit: the Obsidian Karpathy
  LLM Wiki plugin's Monte-Carlo PPR retrieval — made exact here.
- **2026-07-02** 0.9.0 — query-seeded retrieval (`context --query`: lexical
  seeds -> multi-seed exact PPR; deterministic hybrid retrieval, no
  embeddings); doctor gains `duplicate_identity` + info-level
  `hub_concentration`; `reviewed: true` pages are protected from `--fix`.
