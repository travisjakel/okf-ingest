//! Link extraction + resolution — mirrors `py/okf/okf.py` (`extract_links`,
//! `extract_wikilinks`, `_wiki_index`, `resolve_wiki`, `_norm`, `resolve_link`,
//! `links`).

use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

use regex::Regex;

use crate::model::{Bundle, Concept, Link};

fn re_link() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\]\(\s*([^)\s]+)").unwrap())
}

fn re_wikilink() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\[\[([^\]]+)\]\]").unwrap())
}

fn re_scheme() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[a-zA-Z][a-zA-Z0-9+.-]*:").unwrap())
}

/// Markdown link targets: `](target)`.
pub fn extract_links(body: &str) -> Vec<String> {
    re_link()
        .captures_iter(body)
        .map(|c| c[1].to_string())
        .collect()
}

/// `[[wikilink]]` / `[[target|display]]` references (display stripped).
/// Resolved by name (id/alias/title/stem), not path — see [`links`].
pub fn extract_wikilinks(body: &str) -> Vec<String> {
    re_wikilink()
        .captures_iter(body)
        .map(|c| c[1].split('|').next().unwrap_or("").trim().to_string())
        .collect()
}

/// lowercased id/alias/title/stem -> path, per kind. Keys mapping to >1
/// concept are ambiguous and dropped (a wikilink to an ambiguous name resolves
/// to nothing, deterministically). Precedence is applied at resolution.
#[derive(Debug, Default)]
pub struct WikiIndex {
    id: BTreeMap<String, String>,
    alias: BTreeMap<String, String>,
    title: BTreeMap<String, String>,
    stem: BTreeMap<String, String>,
}

fn json_scalar_str(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

pub fn wiki_index(concepts: &[Concept]) -> WikiIndex {
    let mut maps = WikiIndex::default();
    let mut amb: [BTreeSet<String>; 4] = Default::default();

    fn add(map: &mut BTreeMap<String, String>, amb: &mut BTreeSet<String>, key: &str, path: &str) {
        let key = key.trim().to_lowercase();
        if key.is_empty() {
            return;
        }
        if map.get(&key).map(String::as_str).unwrap_or(path) != path {
            amb.insert(key.clone());
        }
        map.insert(key, path.to_string());
    }

    for c in concepts {
        if let Some(fm) = &c.frontmatter {
            if let Some(id) = fm.get("id") {
                if !id.is_null() {
                    add(&mut maps.id, &mut amb[0], &json_scalar_str(id), &c.path);
                }
            }
            if let Some(serde_json::Value::Array(aliases)) = fm.get("aliases") {
                for a in aliases {
                    add(&mut maps.alias, &mut amb[1], &json_scalar_str(a), &c.path);
                }
            }
        }
        if let Some(title) = &c.title {
            if !title.is_empty() {
                add(&mut maps.title, &mut amb[2], title, &c.path);
            }
        }
        let base = c.path.rsplit('/').next().unwrap_or(&c.path);
        let stem = base.rsplit_once('.').map(|(s, _)| s).unwrap_or(base);
        add(&mut maps.stem, &mut amb[3], stem, &c.path);
    }
    for (map, dropped) in [
        (&mut maps.id, &amb[0]),
        (&mut maps.alias, &amb[1]),
        (&mut maps.title, &amb[2]),
        (&mut maps.stem, &amb[3]),
    ] {
        for k in dropped.iter() {
            map.remove(k);
        }
    }
    maps
}

/// Resolve a wikilink reference by exact path, then id/alias/title/stem.
pub fn resolve_wiki(reference: &str, idx: &WikiIndex, known: &BTreeSet<String>) -> Option<String> {
    let reference = reference.split('#').next().unwrap_or("").trim();
    if reference.is_empty() {
        return None;
    }
    if known.contains(reference) {
        return Some(reference.to_string());
    }
    let cand = if reference.ends_with(".md") {
        reference.to_string()
    } else {
        format!("{reference}.md")
    };
    if known.contains(&cand) {
        return Some(cand);
    }
    let lref = reference.to_lowercase();
    for map in [&idx.id, &idx.alias, &idx.title, &idx.stem] {
        if let Some(v) = map.get(&lref) {
            return Some(v.clone());
        }
    }
    None
}

/// Normalize a slash path: drop empty/`.` segments, apply `..`.
fn norm(p: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    let slashed = p.replace('\\', "/");
    for s in slashed.split('/') {
        match s {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            _ => out.push(s),
        }
    }
    out.join("/")
}

fn is_external(raw: &str) -> bool {
    re_scheme().is_match(raw.split('#').next().unwrap_or(""))
}

/// Resolve a markdown link target relative to its source document.
pub fn resolve_link(raw: &str, src_rel: &str, known: &BTreeSet<String>) -> Option<String> {
    let t = raw.split('#').next().unwrap_or("");
    let cand = if let Some(stripped) = t.strip_prefix('/') {
        stripped.to_string()
    } else {
        match src_rel.rsplit_once('/') {
            Some((d, _)) => format!("{d}/{t}"),
            None => t.to_string(),
        }
    };
    let cand = norm(&cand);
    if known.contains(&cand) {
        Some(cand)
    } else {
        None
    }
}

/// Path-valued frontmatter fields (SPEC 6.2): `resource`, `sources[].resource`,
/// `computation`, `executor.resource`, `attester.resource`. Fixed order, so the
/// edge list stays deterministic.
pub fn fm_paths(fm: &Option<serde_json::Map<String, serde_json::Value>>) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let Some(v) = fm else { return out };
    let mut push = |kind: &str, val: Option<&serde_json::Value>| {
        if let Some(s) = val.and_then(|x| x.as_str()) {
            if !s.is_empty() {
                out.push((kind.to_string(), s.to_string()));
            }
        }
    };
    push("resource", v.get("resource"));
    push("computation", v.get("computation"));
    push(
        "executor",
        v.get("executor").and_then(|e| e.get("resource")),
    );
    push(
        "attester",
        v.get("attester").and_then(|e| e.get("resource")),
    );
    match v.get("sources") {
        Some(serde_json::Value::Array(a)) => {
            for s in a {
                push("source", s.get("resource"));
            }
        }
        Some(o @ serde_json::Value::Object(_)) => push("source", o.get("resource")),
        _ => {}
    }
    out
}

/// A `sources[].resource` MAY be a scope descriptor rather than a path (SPEC
/// 5.1), e.g. "all queries in BigQuery project X". A path never contains
/// whitespace, which is the only signal the spec gives.
pub fn is_scope(raw: &str) -> bool {
    raw.chars().any(char::is_whitespace)
}

/// Resolve a path-valued frontmatter field. Applies the SPEC 6.2 reading first
/// (a leading `/` is bundle-relative, otherwise relative to the concept's own
/// directory); if that finds nothing, falls back to the bundle root. The
/// fallback exists because the reference bundles write root-relative paths
/// WITHOUT the leading slash: all 12 frontmatter paths in upstream's
/// `acme_retail` resolve that way and none resolve the spec-literal way, and a
/// consumer is required to be permissive (SPEC 11).
///
/// Returns `(path, how)` where `how` is `"spec"` or `"root"`.
pub fn resolve_path(
    raw: &str,
    src_rel: &str,
    targets: &BTreeSet<String>,
) -> Option<(String, &'static str)> {
    let t = raw.split('#').next().unwrap_or("");
    let spec = match t.strip_prefix('/') {
        Some(stripped) => norm(stripped),
        None => match src_rel.rsplit_once('/') {
            Some((d, _)) => norm(&format!("{d}/{t}")),
            None => norm(t),
        },
    };
    if targets.contains(&spec) {
        return Some((spec, "spec"));
    }
    let root = norm(t.strip_prefix('/').unwrap_or(t));
    if targets.contains(&root) {
        return Some((root, "root"));
    }
    None
}

/// The concept graph. Three edge sources, in this order: markdown links,
/// wikilinks, and the path-valued frontmatter fields of SPEC 6.2. The last
/// group carries the derivation and execution edges, which appear nowhere in
/// the body.
pub fn links(b: &Bundle) -> Vec<Link> {
    let idx = wiki_index(&b.concepts);
    let targets = if b.files.is_empty() {
        &b.known
    } else {
        &b.files
    };
    let mut out = Vec::new();
    for c in &b.concepts {
        for raw in &c.links_raw {
            if is_external(raw) {
                continue;
            }
            let dst = resolve_link(raw, &c.path, &b.known);
            let target = if dst.is_some() {
                "concept"
            } else if resolve_path(raw, &c.path, targets).is_some() {
                "file"
            } else {
                "missing"
            };
            out.push(Link {
                src_path: c.path.clone(),
                dst_raw: raw.clone(),
                resolved: dst.is_some(),
                dst_path: dst,
                kind: "body".to_string(),
                target: target.to_string(),
            });
        }
        for raw in &c.wikilinks_raw {
            let dst = resolve_wiki(raw, &idx, &b.known);
            let target = if dst.is_some() { "concept" } else { "missing" };
            out.push(Link {
                src_path: c.path.clone(),
                dst_raw: raw.clone(),
                resolved: dst.is_some(),
                dst_path: dst,
                kind: "wikilink".to_string(),
                target: target.to_string(),
            });
        }
    }
    // Frontmatter edges are appended last, so body-link ordering is untouched.
    for c in &b.concepts {
        for (kind, raw) in fm_paths(&c.frontmatter) {
            if is_external(&raw) {
                continue;
            }
            if kind == "source" && is_scope(&raw) {
                out.push(Link {
                    src_path: c.path.clone(),
                    dst_raw: raw,
                    dst_path: None,
                    resolved: false,
                    kind,
                    target: "scope".to_string(),
                });
                continue;
            }
            match resolve_path(&raw, &c.path, targets) {
                None => out.push(Link {
                    src_path: c.path.clone(),
                    dst_raw: raw,
                    dst_path: None,
                    resolved: false,
                    kind,
                    target: "missing".to_string(),
                }),
                Some((p, _how)) => {
                    let is_concept = b.known.contains(&p);
                    out.push(Link {
                        src_path: c.path.clone(),
                        dst_raw: raw,
                        dst_path: if is_concept { Some(p) } else { None },
                        resolved: is_concept,
                        kind,
                        target: if is_concept { "concept" } else { "file" }.to_string(),
                    });
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_extraction() {
        let body =
            "see [Orders](orders.md) and [ext](https://x.com) plus [[Concept B|B]] [[b#sec]]";
        assert_eq!(extract_links(body), vec!["orders.md", "https://x.com"]);
        assert_eq!(extract_wikilinks(body), vec!["Concept B", "b#sec"]);
    }

    #[test]
    fn norm_and_resolve() {
        let known: BTreeSet<String> = ["a.md", "sub/b.md"].iter().map(|s| s.to_string()).collect();
        assert_eq!(
            resolve_link("../a.md", "sub/b.md", &known).as_deref(),
            Some("a.md")
        );
        assert_eq!(
            resolve_link("/sub/b.md", "a.md", &known).as_deref(),
            Some("sub/b.md")
        );
        assert_eq!(
            resolve_link("b.md", "sub/x.md", &known).as_deref(),
            Some("sub/b.md")
        );
        assert_eq!(resolve_link("nope.md", "a.md", &known), None);
    }

    #[test]
    fn external_scheme() {
        assert!(is_external("https://x.com"));
        assert!(is_external("mailto:a@b.c"));
        assert!(!is_external("orders.md"));
        assert!(!is_external("metrics/revenue.md"));
    }
}
