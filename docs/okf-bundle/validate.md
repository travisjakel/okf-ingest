---
type: Reference
title: Validate
description: The conformance lint — hard rules (errors) and permissive findings (warnings), with CI exit codes.
timestamp: 2026-06-23T00:00:00Z
tags: [validate, conformance, lint]
---

# Validate

`okf validate` checks a bundle against [the OKF spec](okf-spec.md): the hard rule
(parseable frontmatter with a non-empty `type`) produces **errors**; everything
else — missing recommended fields, broken links, orphans, non-ISO timestamps —
produces **warnings**, never a rejection.

Exit codes make it CI-friendly: `0` conformant, `1` on errors (or warnings under
`--strict`), `2` bad invocation. The findings are stored in [the
catalog](catalog.md) and reused by [doctor](doctor.md), which adds a health score
and maintenance checks on top. All of it is [deterministic](determinism.md).
