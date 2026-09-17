---
type: Attested Computation
title: "Conformance corpus size"
description: "The number of conformance bundles and expected-output fixtures, as a computation rather than a sentence."
tags: [conformance, attested, dogfood]
runtime: r
parameters:
  - { name: root, type: string, required: true }
executor:
  resource: ../skills/run-r.md
  receipt: [run_id, executed_code, result]
attester:
  resource: ../attesters/equality.md
generated: { by: hand, at: 2026-09-17T00:00:00Z }
verified: { by: human:travisjakel, at: 2026-09-17T00:00:00Z }
status: stable
stale_after: 2027-09-17T00:00:00Z
sources:
  - id: corpus
    resource: ../references/conformance-corpus.md
    title: The shared conformance corpus
  - id: bindings-page
    resource: ../bindings.md
    title: The five bindings — the page that states this number
---

# Notes

[The five bindings](../bindings.md) says the corpus is "nine bundles and ten
expected-output fixtures".[^bindings-page] That is a fact about a directory, and
a fact about a directory goes stale the first time somebody adds a fixture and
does not re-read the prose.

So it is carried here instead. Binding `root` to the repository root and running
the block below returns the pair the sentence asserts; an attester compares it
against what the page shows. The point is not that counting files is hard — it
is that the *document* can now be wrong in a way something notices.[^corpus]

This is also the smallest honest demonstration of SPEC 10 in this bundle: a real
`runtime: r` contract over a real directory, with typed parameters, a declared
executor and attester, and a `stale_after` that will make somebody re-verify it
within the year.

**Note the quotes around `"$root"`.** Binding is textual expansion, so a
`type: string` parameter has to be written inside quotes by the author — the
runtime cannot add them without knowing the target language's literal syntax.
Unquoted, `$root` expands to a bare Windows path and the block fails to parse.
The fixture's SQL contracts do not show this because a SQL driver binds `$day`
as a real parameter; a `runtime: r` contract expands into source text.

[^bindings-page]: The five bindings — the page that states this number
[^corpus]: The shared conformance corpus

# Computation

```r
list(
  bundles  = length(list.dirs(file.path("$root", "conformance", "bundles"),
                              recursive = FALSE)),
  fixtures = length(list.files(file.path("$root", "conformance", "expected"),
                               pattern = "[.]json$"))
)
```
