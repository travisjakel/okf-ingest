# OKF conformance — what okf-ingest enforces

Grounded in the OKF v0.1 specification
([GoogleCloudPlatform/knowledge-catalog `okf/SPEC.md`](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)).
This tool is a **consumer** and follows the spec's permissive-consumption rule:
it never *rejects* a bundle for recommended-field issues — it records findings
and loads everything it can.

## Hard rules (severity `error`) — OKF §6 conformance

A bundle is **conformant** iff:

1. Every non-reserved `.md` file contains a **parseable YAML frontmatter block**.
2. Every such frontmatter block contains a **non-empty `type`** field.
3. Reserved files (`index.md`, `log.md`) follow their structure.

`type` is a free string. There is **no enum** — consumers MUST tolerate unknown
types. (Some producers add their own `type` vocabulary (e.g. `Signal`,
`Pipeline`, ...) and extra fields like `status`; those are *extensions*, not part of OKF, and
this tool treats them as ordinary unknown keys — preserved in `frontmatter`.)

## Soft findings (severity `warn`) — never reject the bundle

Per spec, consumers MUST NOT reject a bundle for any of these. We record them so
producers can improve, but ingestion always proceeds:

- Missing recommended fields (`title`, `description`, `resource`, `tags`, `timestamp`).
- `timestamp` present but not ISO-8601 (`YYYY-MM-DDTHH:MM:SSZ`).
- Broken cross-links (target file absent).
- Missing `index.md`.
- Unknown `type` values / unknown extra keys (informational only).

## Cross-links (OKF §4)

Markdown links are untyped directed edges. Two forms resolved:
- **Bundle-absolute** (recommended): begins with `/`, relative to bundle root.
- **Relative**: standard markdown relative path from the source file's dir.

Targets with a URL scheme (`http://`, `mailto:` …) are external and ignored for
the graph. Anchors (`#section`) are stripped before resolution.

## Reserved files

`index.md` (directory listing) and `log.md` (update history) are recognized,
flagged `reserved = true`, and excluded from the `type`-required rule.

## Versioning

`okf_version` is read from the **root** `index.md` frontmatter when present
(e.g. `"0.1"`). An unknown version is loaded best-effort, not refused.
