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
  PRIMARY KEY (bundle_id, path)
);

-- Concept graph: one row per markdown link. Untyped directed edges (OKF §4).
CREATE TABLE IF NOT EXISTS okf_link (
  bundle_id  TEXT,
  src_path   TEXT,                 -- concept that contains the link
  dst_raw    TEXT,                 -- link target exactly as written
  dst_path   TEXT,                 -- resolved bundle-relative path (NULL if unresolved)
  resolved   BOOLEAN               -- spec: consumers MUST tolerate broken links
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
