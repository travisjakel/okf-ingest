---
type: Reference
title: Sources
description: A bundle source can be a local directory, a git URL, or a tar/zip archive (local or remote).
timestamp: 2026-06-23T00:00:00Z
tags: [sources, git, fetch]
---

# Sources

`ingest` (and the read-only verbs) accept a `<source>` that is a local
**directory**, a **git URL** (github/gitlab/bitbucket, `.git`, or `git@`), or a
**tar/zip** archive (local path or `http(s)` URL). Remote sources are fetched to
a temp dir and cleaned up automatically; `--subdir` selects a bundle within a
repo/archive and `--branch` picks a git ref.

Whatever the source, the result is the same [catalog](catalog.md) — fetching is
just transport. Hidden directories (`.git`, `.github`) are skipped identically by
both [bindings](bindings.md), a guarantee locked by [conformance](conformance.md).
See the [CLI](cli.md) for flags.
