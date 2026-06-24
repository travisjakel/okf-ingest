# OKF extensions — design & extensibility reflection

Six gaps were on the table: **wikilinks + aliases**, **typed links**, **stable
ids**, **hierarchy/grouping**, **a `type` vocabulary**, and a **bundle manifest**.
Built naively they'd be six overlapping mechanisms that collide later (two ways to
say "parent", two link tables, three resolvers). The whole point of this spike is
to show they collapse into **three extension points + one resolver**, each
designed to grow without a breaking change.

## The anti-boxing-in thesis

| Apparent feature | Where it actually lives |
|---|---|
| Wikilinks + aliases | the **resolver** (new reference *syntax* + new resolution *keys*) |
| Stable ids | the **resolver** (another resolution key) + a promoted column |
| Typed links | the **edge model** (a nullable `rel` column) |
| Hierarchy / grouping | the **edge model** (`parent:` is just `rel = "parent"`) |
| `type` vocabulary | the **manifest** (declares allowed types/rels; validation is opt-in) |
| Bundle manifest | *is* the manifest extension point |

So: **1 resolver, 1 enriched edge model, 1 manifest** — plus the substrate that
makes all of it safe.

## The substrate: frontmatter is lossless; columns are promoted conventions

`okf_concept.frontmatter` already stores the *entire* parsed frontmatter as JSON.
That means **every new node-level field — `id`, `aliases`, `parent`, `relations`,
anything — is already captured today**, losslessly, with zero schema change. A
"feature" is just: (1) agree on a frontmatter key, (2) optionally *promote* it to
a typed column for querying/indexing. We never have to migrate data; we promote
when a convention stabilises. This is the single most important non-boxing
decision — the format can grow in frontmatter first and harden into columns
later, and an old reader still sees a valid bundle.

Storage rule: **additions are new nullable columns + a `schema_version` stamp.**
Old catalogs stay readable; a new reader detects capability by column presence /
version. No destructive migrations.

## Extension point 1 — the resolver (one function, layered precedence)

A single `resolve(ref, from)` maps *any* reference to a concept, trying keys in a
fixed, data-driven precedence:

```
explicit path  →  id  →  alias  →  title  →  filename-stem
```

- `](path.md)` and `[[Wiki Name]]` and `[[some-id]]` and a `relations:` target all
  flow through the *same* resolver — they differ only in **syntax of the
  reference**, not in resolution.
- Linking by `id`/`title`/`alias` instead of `path` is what makes renames safe —
  **rename-robustness falls out of the resolver for free**, it is not a separate
  feature.
- **Why this doesn't box us in:** new reference kinds (a UUID scheme, a
  cross-bundle `bundle:concept` ref) become *new entries in the precedence list*,
  not new code paths. Ambiguity (two concepts share a title) resolves to *nothing*
  + a warning today; a future precedence/`disambiguation:` rule can refine it
  without changing callers.
- **What we deliberately don't lock in:** path stays the canonical identity by
  default (ids are opt-in), so we never force a migration on existing bundles.

## Extension point 2 — the enriched edge model (one table, two nullable columns)

`okf_link` gains exactly two additive, nullable columns:

- `rel` — the relationship type (`NULL` = an untyped markdown link, i.e. today).
- `link_kind` — `markdown` | `wikilink` | `relation` (provenance of the edge).

Everything edge-shaped routes here:

- **Typed links** — `rel` set from a `relations:` frontmatter block *or* an inline
  link title (`[x](y.md "rel: depends-on")`).
- **Hierarchy** — `parent: a.md` emits an edge with `rel = "parent"`. There is **no
  separate hierarchy subsystem**; a tree is just `SELECT … WHERE rel='parent'`,
  exposed as a *view*, never a duplicated column. (This is the realisation that
  prevents the worst boxing-in: a `parent_path` column *and* typed links would be
  two overlapping truths.)
- **Untyped links** — `rel IS NULL`, exactly as the shipped tool behaves.

- **Why this doesn't box us in:** `rel` is a free string (like `type`). Any future
  relationship — `contradicts`, `supersedes`, `derived-from` — works with no
  schema change, and is optionally constrained by the manifest's vocabulary.
- **What we deliberately don't lock in:** we do **not** invent bespoke link syntax
  for every relation. Structured (`relations:`) is the primary, machine-stable
  form; the inline title is sugar. Overloading markdown syntax is the thing that
  ages badly, so it stays secondary.

## Extension point 3 — the bundle manifest (one open document)

An optional, reserved `okf.yml` at the bundle root holds **all** bundle-level
config, so we never proliferate reserved files:

```yaml
name: my-knowledge
version: 1.2.0
okf_version: "0.1"
license: CC-BY-4.0
types:                      # the type vocabulary — STRUCTURED, not a flat enum
  Concept: {}
  Method:  { requires: [timestamp] }   # room to grow into per-type schemas
relations: [depends-on, see-also, parent]
```

- The **type vocabulary** lives here. Validation against it is **opt-in and a
  warning** — no manifest ⇒ free-string types, exactly as today.
- **Why structured, not a flat list:** declaring `types:` as a *map* (even if the
  prototype only checks membership) leaves room for **per-type required fields /
  schemas** later — without changing the manifest shape. A flat `[Concept, Method]`
  enum would have boxed that out.
- **Why this doesn't box us in:** unknown manifest keys are ignored, not rejected,
  so future config (capabilities, default relation, embedding model, render theme)
  lands here additively. One open document, read leniently.
- **What we deliberately don't lock in:** the manifest is **optional**. A bundle
  with no `okf.yml` is fully valid; conformance is still "every non-reserved file
  has a non-empty `type`".

## Compatibility guarantees (the contract that keeps us free)

1. **Conformance is unchanged** — still just: parseable frontmatter + non-empty
   `type`. Every new field is recommended-or-ignored, never required.
2. **Existing bundles are untouched** — no wikilinks, no `rel`, no manifest ⇒
   identical catalog to the shipped tool. New columns are nullable.
3. **Everything is additive + versioned** — `schema_version` on the bundle row;
   readers degrade gracefully.
4. **Cross-binding parity still holds** — the same enriched catalog is producible
   by R and Python; the conformance corpus would gain fixtures, not change shape.
5. **It composes with the deterministic / no-agents stance** — none of this needs
   a model. Resolution, edge typing, vocabulary checks are all mechanical.

## What this spike implements (see `okf_ext.R` + `demo/`)

A single R prototype demonstrating all six through the three extension points:
the layered resolver (path/id/alias/title/stem), `[[wikilink]]` + `aliases:`,
`relations:` + inline typed links, `parent:` as a `rel="parent"` edge, an `okf.yml`
manifest with a structured `types:` vocabulary, and opt-in vocabulary validation —
on a demo bundle that exercises each, including a deliberate out-of-vocabulary type
and an unresolved wikilink to show the warning paths.
