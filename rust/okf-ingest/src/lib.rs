//! okf-ingest — Open Knowledge Format ingestion (Rust binding).
//!
//! The fixture-locked core of the OKF toolchain, byte-identical with the R
//! (`r/okf`) and Python (`py/okf`) bindings on the shared conformance
//! fixtures (`conformance/`): frontmatter parsing + body normalization
//! (`content_hash`), link + `[[wikilink]]` extraction/resolution, OKF
//! validation, ingest summaries, exact Personalized-PageRank ranking, lexical
//! query seeding, concept-level diff, and bundle fetch (dir / tar / zip /
//! git).
//!
//! Out of scope by design (use the R or Python binding): HTML render, doctor,
//! graph exports, RAG/embeddings, CLI, DuckDB catalog (the ingest summary is
//! computed in memory; every conformance-asserted value is available on
//! [`Ingested`]).
//!
//! ```no_run
//! use okf_ingest::{ingest, ppr, seeds, PprOptions};
//!
//! let ing = ingest("path/to/bundle").unwrap();
//! assert!(ing.summary.conformant);
//! let ranked = ppr(&ing, &["index.md"], &PprOptions::default()).unwrap();
//! let hits = seeds(&ing, "how is revenue computed?", 5);
//! # let _ = (ranked, hits);
//! ```

mod diff;
mod fetch;
mod graph;
mod ignore;
mod ingest;
mod links;
mod model;
mod parse;
mod read;
mod validate;

pub use diff::{diff, Diff, DiffSide, DiffSummary, EdgeDelta, FieldChange};
pub use fetch::{fetch, Fetched};
pub use graph::{ppr, round_dec, seeds, PprOptions, RankRow, Seed, OKF_STOPWORDS};
pub use ignore::{is_ignored, IGNORE_FILE};
pub use ingest::{ingest, ingest_bundle};
pub use links::{extract_links, extract_wikilinks, links, resolve_link, resolve_wiki, wiki_index};
pub use model::{
    Bundle, Concept, Finding, Ingested, Link, OkfError, Severity, SourceKind, Summary, RESERVED,
};
pub use parse::{content_hash, parse_text, Parsed};
pub use read::read_bundle;
pub use validate::validate;
