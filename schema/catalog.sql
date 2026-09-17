-- ============================================================================
-- okf-ingest catalog schema v1 — the cross-language interoperability contract.
--
-- Both the R and Python bindings write byte-identical catalogs against this
-- schema, so an ingested bundle is portable and queryable from either language
-- (or the bare `duckdb` CLI). Works in DuckDB; SQLite-compatible except where
-- noted (JSON columns are TEXT in SQLite). List/JSON-valued fields are stored
-- as JSON strings so the format is identical across engines and languages.
-- ============================================================================

CREATE TABLE IF NOT EXISTS okf_bundle (
  bundle_id    TEXT PRIMARY KEY,   -- stable id (sha1 of root realpath unless given)
  root         TEXT,               -- absolute path / URI the bundle was read from
  okf_version  TEXT,               -- from root index.md frontmatter, else NULL
  source_kind  TEXT,               -- 'dir' | 'git' | 'tar' | 'zip'
  ingested_at  TEXT,               -- ISO-8601; supplied by caller (not wall-clock in lib)
  n_concepts   INTEGER,
  n_conformant INTEGER,            -- concepts passing the 2 hard rules
  conformant   BOOLEAN             -- bundle-level: all non-reserved files pass
);

CREATE TABLE IF NOT EXISTS okf_concept (
  bundle_id    TEXT,
  path         TEXT,               -- bundle-relative path = the concept's identity
  reserved     BOOLEAN,            -- index.md / log.md
  type         TEXT,               -- REQUIRED by spec (NULL only on a violation row)
  title        TEXT,
  description  TEXT,
  resource     TEXT,
  tags         TEXT,               -- JSON array of strings
  timestamp    TEXT,               -- ISO-8601 as authored (kept verbatim)
  body         TEXT,
  frontmatter  TEXT,               -- full frontmatter as JSON (preserves unknown keys)
  parse_error  TEXT,               -- NULL if frontmatter parsed cleanly
  content_hash TEXT,
  -- Derived v0.2 trust and lifecycle (SPEC 5), which SPEC 11 asks consumers to
  -- derive "only from the fields specified here". `status` is NULL unless the
  -- value is in the closed SPEC 5.4 vocabulary; `status_raw` keeps what was
  -- authored, because producer extensions reuse this key.
  status       TEXT,               -- draft | stable | deprecated
  status_raw   TEXT,
  stale_after  TEXT,               -- absolute instant (SPEC 5.5)
  trust_tier   TEXT,               -- unverified | machine-confirmed | human-reviewed
  verified_at  TEXT,               -- latest verification instant
  verified_by  TEXT,
  generated_by TEXT,
  PRIMARY KEY (bundle_id, path)
);
-- SPEC 5.1 provenance: one row per `sources[]` entry, signals as authored.
-- The spec records objective signals and refuses to store a credibility SCORE
-- (subjective, unportable, goes stale), so neither do we -- `cited` is the
-- footnote-label join into `sources[].id` that the spec defines.
CREATE TABLE IF NOT EXISTS okf_source (
  bundle_id     TEXT,
  path          TEXT,              -- concept carrying the entry
  idx           INTEGER,           -- 1-based position in sources[]
  id            TEXT,
  resource      TEXT,
  title         TEXT,
  author        TEXT,              -- actor convention (SPEC 7)
  usage_count   TEXT,              -- verbatim; a coarse liveness signal
  last_modified TEXT,
  is_scope      BOOLEAN,           -- a scope descriptor, not a path (SPEC 5.1)
  cited         BOOLEAN            -- a [^id] footnote attributes a claim to it
);

-- SPEC 10 Attested Computations. Contract only: okf-ingest reads and binds,
-- and executes nothing.
CREATE TABLE IF NOT EXISTS okf_computation (
  bundle_id        TEXT,
  path             TEXT,
  runtime          TEXT,           -- REQUIRED for the type (SPEC 10.2)
  form             TEXT,           -- inline | file | none | both
  computation_path TEXT,
  computation      TEXT,           -- the text, from whichever form is present
  n_parameters     INTEGER,
  parameters       TEXT,           -- JSON array of {name, type, required}
  executor         TEXT,
  receipt          TEXT,           -- JSON array of required receipt fields
  attester         TEXT
);


-- Concept graph: one row per reference. Untyped directed edges (OKF §6).
-- Body links and [[wikilinks]] come first, then the path-valued frontmatter
-- fields of §6.2 -- those carry the derivation and execution edges.
CREATE TABLE IF NOT EXISTS okf_link (
  bundle_id  TEXT,
  src_path   TEXT,                 -- concept that contains the reference
  dst_raw    TEXT,                 -- target exactly as written
  dst_path   TEXT,                 -- resolved bundle-relative path (NULL if not a concept)
  resolved   BOOLEAN,              -- spec: consumers MUST tolerate broken links
  kind       TEXT,                 -- body | wikilink | resource | source
                                   --   | computation | executor | attester
  target     TEXT                  -- concept | file | scope | missing
);

-- Conformance findings. severity: 'error' = breaks a hard rule (OKF §6);
-- 'warn' = recommended-field/permissive issue (never rejects the bundle).
CREATE TABLE IF NOT EXISTS okf_validation (
  bundle_id TEXT,
  path      TEXT,
  severity  TEXT,
  rule      TEXT,
  message   TEXT
);

-- Optional "+queryable index" layer: body chunks + embeddings for search/RAG.
-- embedding stays NULL unless an embedder is supplied at ingest time.
CREATE TABLE IF NOT EXISTS okf_chunk (
  bundle_id    TEXT,
  path         TEXT,
  chunk_id     INTEGER,
  text         TEXT,
  embedding    FLOAT[],             -- DuckDB; in SQLite store as a BLOB/JSON instead
  content_hash TEXT                 -- concept hash at embed time (enables incremental re-embed)
);
