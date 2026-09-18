---
type: Reference
title: .okfignore
description: How a bundle declares which .md files were never concept documents, and the exact matching grammar all five bindings share.
timestamp: 2026-09-18T00:00:00Z
generated: { by: hand, at: 2026-09-18T00:00:00Z }
status: stable
tags: [okfignore, conformance, validate]
---

# `.okfignore`

SPEC 3.1 reserves exactly two filenames — `index.md` and `log.md` — and then
says *"All other `.md` files are concept documents."* That leaves a bundle no
way to say that its `README.md`, its `schema.md`, or a vendored deployment doc
was never a concept. Each one fails [the hard `type:` rule](validate.md), so a
conformant bundle is unreachable for any repository that is also a repository.

The alternative "fix" is to write `type: Doc` on a README. That is a lie told
to a validator: it buys a green check by making the catalog claim a concept
exists where none does. `.okfignore` is the honest version — the producer
states the file is not a concept, and the consumer believes it.

## What ignoring does

An ignored file **leaves the concept set and stays in the file set**. It is
exactly what it always was: an ordinary file in the tree.

- It is not a row in [the catalog](catalog.md)'s `okf_concept`, so it is never
  validated, never counted in `n_concepts`, never an orphan, never ranked.
- It remains in `Bundle.files`, so a reference to it still **resolves**. A link
  to an ignored README is an `info` finding — `non_concept_target`, the same
  one a [SPEC 6.2](okf-spec.md) path to an attester `.py` produces — and not a
  broken link.
- **The catalog schema is unchanged.** Nothing was added to `okf_concept`;
  ignoring is a decision about membership, not a new column.

`index.md` and `log.md` can never be ignored. A bundle able to hide its own
index would lose its `okf_version` and its directory listing, so an ignore file
cannot un-structure the bundle. A pattern that matches one is silently inert.

## Where it lives

One file, `.okfignore`, at the **bundle root**. There is no per-directory
cascade.

That is the single most important restriction and it is deliberate. Five
bindings have to agree on this grammar exactly, and gitignore's per-directory
cascade and its negation-of-negation corners are precisely where independent
implementations drift apart. One file, no cascade, and a
[fixture](conformance.md) that pins every rule.

The file itself is never a bundle member: all five readers already skip
dotfiles, so it is read explicitly by path.

## The grammar

UTF-8, one pattern per line.

| Rule | Behaviour |
|---|---|
| blank line, or first non-space character `#` | skipped |
| surrounding whitespace | trimmed |
| leading `!` | re-includes; **the last matching line decides** |
| trailing `/` | directory pattern — matches everything beneath it |
| no `/` in the pattern | matches the **basename**, at any depth |
| any `/` in the pattern | **anchored** at the bundle root |
| `?` | exactly one character, never `/` |
| `*` | any run of characters, never `/` |
| `**` | any run of characters, including `/` |
| `/**/` | also matches a single `/`, so `a/**/b` matches `a/b` |

Matching is case-sensitive. There are no other metacharacters: `.`, `+`, `(`,
`[` and the rest are literal. A pattern that fails to compile is skipped rather
than raising, because [a consumer must be permissive](okf-spec.md).

`/**/` earns its special case: without it, the pattern everyone writes first
silently matches nothing at the one depth they meant.

## Example

```
# Scaffolding, not concepts.
README.md
CONTRIBUTING.md
schema.md

# Vendored deployment docs, at any depth.
_scratch/

# Anchored: only this one, not every vendor/ in the tree.
pkg/vendor/

*.draft.md
notes/**/tmp.md

# Keep one file an earlier pattern swept up.
!pkg/vendor/keep.md
```

## Seeing what it did

An ignored file produces **no findings at all**, which is indistinguishable
from a clean one. An over-broad pattern would therefore read as a bundle that
got healthier rather than one that got smaller — so the effect is always
reported:

```
$ okf validate my-bundle
bundle: my-bundle
conformant: TRUE  (errors: 0, warnings: 0)
ignored: 7 file(s) via .okfignore (README.md, a/_scratch/note.md, b.draft.md, ...)
```

`--json` carries the full list under `ignored`. In code: `okf_ignored(root)` in
R, `okf.ignored(root)` in Python, and `ignored` on the bundle in all five
bindings.

## Parity

`conformance/bundles/okfignore` and `expected/okfignore.json` lock the grammar
across [the five bindings](bindings.md). Every one of its seven ignored files
carries **no frontmatter at all**, so `errors: 0` is reachable only if each
rule actually matched — the fixture is discriminating rather than merely
consistent. Three surviving concepts are negative controls: one re-included by
a `!` line, one proving an anchored directory pattern does not match the same
directory name elsewhere, and one inside a directory a `**` pattern traverses.

See also [validate](validate.md), [conformance](conformance.md) and
[the catalog](catalog.md).
