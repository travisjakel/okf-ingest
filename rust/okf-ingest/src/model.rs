//! Core data model — mirrors `py/okf/okf.py` dataclasses / `r/okf/R/okf.R` lists.

use std::collections::BTreeSet;
use std::fmt;

/// Reserved bundle documents: catalogued (`reserved = true`) but never counted
/// as concepts and never validated for frontmatter conformance.
pub const RESERVED: [&str; 2] = ["index.md", "log.md"];

/// How a bundle was materialized (mirrors the `source_kind` catalog column).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    Dir,
    Git,
    Tar,
    Zip,
}

impl SourceKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            SourceKind::Dir => "dir",
            SourceKind::Git => "git",
            SourceKind::Tar => "tar",
            SourceKind::Zip => "zip",
        }
    }
}

/// One parsed bundle document.
#[derive(Debug, Clone)]
pub struct Concept {
    /// Bundle-relative path, forward slashes.
    pub path: String,
    pub reserved: bool,
    pub kind: Option<String>, // frontmatter `type` (renamed: `type` is a keyword)
    pub title: Option<String>,
    pub description: Option<String>,
    pub resource: Option<String>,
    /// Frontmatter `tags`, JSON-shaped (serialized for catalog/seed matching).
    pub tags: Option<serde_json::Value>,
    /// Verbatim string — never coerced to a date type (parity rule).
    pub timestamp: Option<String>,
    pub body: String,
    pub frontmatter: Option<serde_json::Map<String, serde_json::Value>>,
    /// `no_frontmatter` | `unclosed_frontmatter` | `yaml_parse_error`.
    pub parse_error: Option<String>,
    pub links_raw: Vec<String>,
    pub wikilinks_raw: Vec<String>,
    /// sha1 hex of the normalized body (cross-language parity lock).
    pub content_hash: String,
}

#[derive(Debug, Clone)]
pub struct Bundle {
    pub bundle_id: String,
    pub root: String,
    pub okf_version: Option<String>,
    pub source_kind: SourceKind,
    /// Sorted by `path` (byte order) — load-bearing for PPR determinism.
    pub concepts: Vec<Concept>,
    pub known: BTreeSet<String>,
    /// Every file in the tree, not only concepts: SPEC 6.2 path-valued fields
    /// and SPEC 6.3 `references/` point at non-markdown artifacts (an attester
    /// .py, a computation .sql). Those are real targets, not broken links.
    pub files: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    pub src_path: String,
    pub dst_raw: String,
    pub dst_path: Option<String>,
    pub resolved: bool,
    /// body | wikilink | resource | source | computation | executor | attester
    pub kind: String,
    /// concept | file | scope | missing
    pub target: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warn,
    Info,
}

impl Severity {
    pub fn as_str(&self) -> &'static str {
        match self {
            Severity::Error => "error",
            Severity::Warn => "warn",
            Severity::Info => "info",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Finding {
    pub path: String,
    pub severity: Severity,
    pub rule: String,
    pub message: String,
}

/// The ingest summary — the fixture-locked fields of `check_py.py`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    pub n_files: usize,
    pub n_concepts: usize,
    pub n_conformant: usize,
    pub conformant: bool,
    pub errors: usize,
    pub warnings: usize,
    pub links_total: usize,
    pub links_broken: usize,
}

/// The in-memory "catalog": everything the conformance contract reads back.
#[derive(Debug, Clone)]
pub struct Ingested {
    pub bundle: Bundle,
    pub links: Vec<Link>,
    pub findings: Vec<Finding>,
    pub summary: Summary,
}

#[derive(Debug)]
pub enum OkfError {
    Io(std::io::Error),
    Msg(String),
}

impl fmt::Display for OkfError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            OkfError::Io(e) => write!(f, "{e}"),
            OkfError::Msg(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for OkfError {}

impl From<std::io::Error> for OkfError {
    fn from(e: std::io::Error) -> Self {
        OkfError::Io(e)
    }
}

impl OkfError {
    pub fn msg(m: impl Into<String>) -> Self {
        OkfError::Msg(m.into())
    }
}
