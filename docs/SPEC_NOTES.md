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
  (JSON-shaped), queryable via the catalog's `frontmatter` column. Since
  0.12.0 the R and Python bindings also DERIVE from them (SPEC 11):
  `okf_trust()` / `okf.trust()` give the SPEC 5.3 trust tier and SPEC 5.5
  staleness, and `okf_doctor()` reports `stale_after_passed`,
  `status_not_spec_vocabulary` and `family_not_spec_shape`. None of this
  affects conformance.
- **Timestamp form** (SPEC 5; literal since upstream PR #6, 2026-08-21):
  every timestamp-valued key is an ISO-8601 datetime with an explicit offset.
  Two older forms still appear in v0.2 bundles, and they are handled
  differently:
  - A bare `YYYY-MM-DD` was the normative `stale_after` form before PR #6. It
    reads as midnight UTC (since 0.13.1), which is the earliest reading of
    the date, so the concept goes stale no later than its writer meant.
  - A local datetime with no offset has no defined instant and is ignored.

  Either form raises the doctor rule `timestamp_not_instant` (warn), which
  names each key.
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

## Upstream status (checked 2026-10-21)

- The spec is still **v0.2**. PR #6 (2026-08-21) is the only normative change
  since v0.2 was released, and it shipped without a version bump (upstream
  issue #24).
- Our path-resolution report, issue #29, is still open, as is PR #31.
- Upstream has 23 open community proposals: typed relationships (#16, #30),
  `supersedes`/`contested_by` (#22), a `refuted` trust value (#13), `imported`
  attribution (#15), withheld sources (#32), deletion semantics (#11) and a
  JSON Schema (#8). None has a maintainer response, so none is implemented
  here. Experiments belong on the `prototype/okf-extensions` branch as unknown
  keys, which the spec already requires consumers to preserve.
