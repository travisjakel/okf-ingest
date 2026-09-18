---
type: Index
title: okfignore fixture
okf_version: "0.2"
generated: { by: process:conformance/bundles/okfignore, at: 2026-09-18T00:00:00Z }
status: stable
---

# okfignore fixture

Locks the `.okfignore` convention: a producer's declaration that some `.md`
files in its tree were never concept documents.

## Concepts

- [concept](concept.md)
- [docs/real](docs/real.md)
- [pkg/vendor/keep](pkg/vendor/keep.md) — re-included by a `!` line
- [other/vendor/live](other/vendor/live.md) — `pkg/vendor/` is anchored
- [notes/x/keep](notes/x/keep.md)

## Not a concept

[README](README.md) is ignored, so this reference resolves to an ordinary
file in the tree, not to a concept and not to a broken link.
