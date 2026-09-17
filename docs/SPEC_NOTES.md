# OKF conformance — what okf-ingest enforces

Grounded in the OKF specification, v0.2
([GoogleCloudPlatform/open-knowledge-format `SPEC.md`](https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md);
the former copy under `knowledge-catalog/okf/` was retired 2026-08-21 and is no longer maintained);
v0.1 bundles remain fully supported (v0.2 §13 keeps them consumable).
This tool is a **consumer** and follows the spec's permissive-consumption rule:
it never *rejects* a bundle for recommended-field issues — it records findings
and loads everything it can.

## Hard rules (severity `error`) — OKF §11 conformance

Unchanged between v0.1 and v0.2. A bundle is **conformant** iff:

1. Every non-reserved `.md` file contains a **parseable YAML frontmatter block**.
2. Every such frontmatter block contains a **non-empty `type`** field.
3. Reserved files (`index.md`, `log.md`) follow their structure.

`type` is a free string. There is **no enum** — consumers MUST tolerate unknown
types. That includes v0.2's `Attested Computation`: it loads as an ordinary
concept whose extra fields (`runtime`, `parameters`, `executor`, `attester`)
are preserved in `frontmatter`; okf-ingest does not execute or attest anything.

## Soft findings (severity `warn`) — never reject the bundle

Per spec, consumers MUST NOT reject a bundle for any of these. We record them so
producers can improve, but ingestion always proceeds:

- Missing recommended fields (`title`, `description`, `resource`, `tags`),
  and missing freshness: neither `generated.at` (v0.2) nor legacy `timestamp`
  (v0.1) present.
- Freshness value present but not ISO-8601 (`YYYY-MM-DDTHH:MM:SSZ`).
- Broken cross-links (target file absent).
- Missing `index.md`.
- Unknown `type` values / unknown extra keys (informational only).

## v0.2 field families — what okf-ingest does with them

- **`generated: { by, at }`** (replaces `timestamp`): the concept `timestamp`
  field — and therefore the catalog column, validation, html metadata, and
  diff — resolves as *`timestamp`, falling back to `generated.at`* (the spec's
  §13 fallback, applied in every binding and locked by the `v02` conformance
  fixture).
- **`sources`**, **`verified`**, **`usage_window`**, **`status`**,
  **`stale_after`**: parsed and preserved verbatim in `frontmatter`
  (JSON-shaped), queryable via the catalog's `frontmatter` column. No trust
  tiers or staleness findings are derived yet (candidate for a future
  release); nothing about them affects conformance.
- **Legacy `# Citations` body lists**: not parsed (the spec makes reading them
  a MAY; `sources` is the v0.2 form).
- **Actor convention** (`producer/version`, `human:<id>`, `process:<id>`):
  treated as opaque strings.

## Cross-links (OKF §6)

Markdown links are untyped directed edges. Two forms resolved:
- **Bundle-absolute** (recommended): begins with `/`, relative to bundle root.
- **Relative**: standard markdown relative path from the source file's dir.

Targets with a URL scheme (`http://`, `mailto:` …) are external and ignored for
the graph. Anchors (`#section`) are stripped before resolution.

`[[wikilinks]]` are an okf-ingest **extension** (vault compatibility) — the
spec, v0.2 included, defines markdown links only.

## Reserved files

`index.md` (directory listing) and `log.md` (update history) are recognized,
flagged `reserved = true`, and excluded from the `type`-required rule.

## Versioning

`okf_version` is read from the **root** `index.md` frontmatter when present
(`"0.1"`, `"0.2"`). An unknown version is loaded best-effort, not refused.
