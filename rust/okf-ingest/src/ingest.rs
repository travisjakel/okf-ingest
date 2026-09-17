//! Ingest — mirrors `py/okf/okf.py::ingest`/`_ingest_bundle`, catalog-free.
//!
//! The conformance contract asserts only values derivable in memory (summary
//! fields, content hashes, findings, link resolutions), so the core `ingest`
//! returns an [`Ingested`] instead of writing a DuckDB catalog. A catalog
//! writer can ship later behind a `catalog` cargo feature.

use std::collections::BTreeSet;
use std::path::Path;

use crate::fetch::fetch;
use crate::links::links;
use crate::model::{Bundle, Ingested, OkfError, Severity, SourceKind, Summary};
use crate::read::read_bundle;
use crate::validate::validate;

/// Pure summary computation over an in-memory bundle.
pub fn ingest_bundle(bundle: Bundle) -> Ingested {
    let findings = validate(&bundle);
    let lk = links(&bundle);

    let err_paths: BTreeSet<&str> = findings
        .iter()
        .filter(|f| f.severity == Severity::Error)
        .map(|f| f.path.as_str())
        .collect();
    let non_reserved: Vec<&str> = bundle
        .concepts
        .iter()
        .filter(|c| !c.reserved)
        .map(|c| c.path.as_str())
        .collect();
    let n_conformant = non_reserved
        .iter()
        .filter(|p| !err_paths.contains(*p))
        .count();

    let summary = Summary {
        n_files: bundle.concepts.len(),
        n_concepts: non_reserved.len(),
        n_conformant,
        conformant: err_paths.is_empty(),
        errors: findings
            .iter()
            .filter(|f| f.severity == Severity::Error)
            .count(),
        warnings: findings
            .iter()
            .filter(|f| f.severity == Severity::Warn)
            .count(),
        links_total: lk.len(),
        links_broken: lk.iter().filter(|l| l.target == "missing").count(),
    };
    Ingested {
        bundle,
        links: lk,
        findings,
        summary,
    }
}

/// Ingest from a source: bundle directory, local tar/zip archive, or git URL.
pub fn ingest(source: &str) -> Result<Ingested, OkfError> {
    if Path::new(source).is_dir() {
        let b = read_bundle(Path::new(source), None, SourceKind::Dir)?;
        return Ok(ingest_bundle(b));
    }
    let fetched = fetch(source, None, None)?;
    let b = read_bundle(&fetched.dir, None, fetched.kind)?;
    Ok(ingest_bundle(b))
}
