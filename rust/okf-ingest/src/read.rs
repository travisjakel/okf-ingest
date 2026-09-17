//! Bundle reading — mirrors `py/okf/okf.py::read_bundle`.
//!
//! Parity rules: hidden directories (`.git`, `.github`, …) are skipped; only
//! `*.md` files not starting with `.`; concepts sorted by bundle-relative
//! forward-slash path in byte order (== code-point order == the catalog's
//! `ORDER BY path`).

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf, MAIN_SEPARATOR as MAIN_SEP};

use crate::links::{extract_links, extract_wikilinks};
use crate::model::{Bundle, Concept, OkfError, SourceKind, RESERVED};
use crate::parse::{content_hash, meta_get, parse_text, scalar_str, yaml_to_json};

/// Canonicalize to a forward-slash string, stripping the Windows `\\?\` prefix.
fn canon_str(root: &Path) -> std::io::Result<String> {
    let c = fs::canonicalize(root)?;
    let s = c.to_string_lossy().replace('\\', "/");
    Ok(s.strip_prefix("//?/").map(str::to_string).unwrap_or(s))
}

fn walk_md(dir: &Path, out: &mut Vec<PathBuf>, all: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        let path = entry.path();
        if path.is_dir() {
            if !name.starts_with('.') {
                walk_md(&path, out, all)?;
            }
        } else if !name.starts_with('.') {
            all.push(path.clone());
            if name.ends_with(".md") {
                out.push(path);
            }
        }
    }
    Ok(())
}

/// Read an OKF bundle directory into memory.
pub fn read_bundle(
    root: &Path,
    bundle_id: Option<&str>,
    source_kind: SourceKind,
) -> Result<Bundle, OkfError> {
    let root_str = canon_str(root)?;
    let root_path = PathBuf::from(&root_str);
    let mut files = Vec::new();
    let mut all_paths = Vec::new();
    walk_md(&root_path, &mut files, &mut all_paths)?;
    let mut all_files: BTreeSet<String> = BTreeSet::new();
    for f in &all_paths {
        if let Ok(r) = f.strip_prefix(&root_path) {
            all_files.insert(r.to_string_lossy().replace(MAIN_SEP, "/"));
        }
    }

    let mut concepts: Vec<Concept> = Vec::with_capacity(files.len());
    for f in &files {
        let rel = f
            .strip_prefix(&root_path)
            .map_err(|e| OkfError::msg(e.to_string()))?
            .to_string_lossy()
            .replace('\\', "/");
        let text = fs::read_to_string(f)?;
        let p = parse_text(&text);
        let basename = rel.rsplit('/').next().unwrap_or(&rel);
        let (kind, title, description, resource, tags, timestamp, frontmatter) = match &p.meta {
            Some(h) => (
                meta_get(h, "type").and_then(scalar_str),
                meta_get(h, "title").and_then(scalar_str),
                meta_get(h, "description").and_then(scalar_str),
                meta_get(h, "resource").and_then(scalar_str),
                meta_get(h, "tags").map(yaml_to_json),
                // OKF v0.2: fall back to `generated: {by, at}` when the
                // legacy `timestamp` is absent (spec section 13).
                meta_get(h, "timestamp").and_then(scalar_str).or_else(|| {
                    meta_get(h, "generated").and_then(|g| match g {
                        yaml_rust2::Yaml::Hash(gh) => meta_get(gh, "at").and_then(scalar_str),
                        _ => None,
                    })
                }),
                {
                    let mut m = serde_json::Map::new();
                    for (k, v) in h.iter() {
                        m.insert(scalar_str(k).unwrap_or_default(), yaml_to_json(v));
                    }
                    Some(m)
                },
            ),
            None => (None, None, None, None, None, None, None),
        };
        concepts.push(Concept {
            reserved: RESERVED.contains(&basename),
            path: rel,
            kind,
            title,
            description,
            resource,
            tags,
            timestamp,
            links_raw: extract_links(&p.body),
            wikilinks_raw: extract_wikilinks(&p.body),
            content_hash: content_hash(&p.body),
            body: p.body,
            frontmatter,
            parse_error: p.err.map(str::to_string),
        });
    }
    concepts.sort_by(|a, b| a.path.cmp(&b.path));

    let known: BTreeSet<String> = concepts.iter().map(|c| c.path.clone()).collect();
    let okf_version = concepts
        .iter()
        .find(|c| c.path == "index.md")
        .and_then(|c| c.frontmatter.as_ref())
        .and_then(|fm| fm.get("okf_version"))
        .and_then(json_scalar);
    let bundle_id = match bundle_id {
        Some(b) => b.to_string(),
        None => content_hash(&root_str),
    };
    Ok(Bundle {
        bundle_id,
        root: root_str,
        okf_version,
        source_kind,
        concepts,
        known,
        files: all_files,
    })
}

/// JSON value -> string, mirroring `_s` on the frontmatter map (`None` for
/// arrays/objects/null). Kept private to `okf_version` lookup; scalar fields
/// come straight from YAML via [`scalar_str`].
fn json_scalar(v: &serde_json::Value) -> Option<String> {
    match v {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Number(n) => Some(n.to_string()),
        serde_json::Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}
