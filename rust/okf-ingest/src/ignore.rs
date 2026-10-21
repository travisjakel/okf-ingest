//! `.okfignore` — a producer's declaration that some `.md` files in its tree
//! are not concept documents.
//!
//! SPEC 3.1 reserves exactly two filenames and then says "All other `.md` files
//! are concept documents", which leaves a bundle no way to say that its README,
//! its `schema.md`, or a vendored deployment doc was never a concept. Every one
//! of them fails the hard `type:` rule, so a conformant bundle is unreachable
//! for any repository that is also a repository. The alternative "fix" is to
//! put `type: Doc` on a README, which is a lie told to a validator.
//!
//! An ignored file leaves the CONCEPT set and stays in the FILE set, so it is
//! exactly what it always was: an ordinary file in the tree. A reference to it
//! resolves as `non_concept_target` (info, SPEC 6.2/6.3) instead of as a broken
//! link, and nothing about the catalog schema changes.
//!
//! Mirrors `r/okf/R/okf.R` and `py/okf/okf.py`; the grammar is locked across
//! all five bindings by `conformance/bundles/okfignore`.

use crate::model::RESERVED;
use regex::Regex;
use std::path::Path;

pub const IGNORE_FILE: &str = ".okfignore";

/// Characters escaped to stay literal in every binding's regex engine.
/// Everything else — `/`, `-`, `_`, alphanumerics, any non-ASCII — passes
/// through UNESCAPED, because this crate's regex engine REJECTS an
/// unrecognized escape (`\/` is an error here, not a literal slash) where PCRE
/// and `std::regex` accept it. Escaping only the true metacharacters is the one
/// rule all five agree on.
const GLOB_META: &[char] = &[
    '.', '\\', '+', '*', '?', '(', ')', '[', ']', '{', '}', '^', '$', '|',
];

pub struct Rule {
    rx: Regex,
    neg: bool,
    dir_only: bool,
    anchored: bool,
}

/// Translate one `.okfignore` pattern into a fully anchored regex.
///
/// A deliberately small, completely specified subset of gitignore: five
/// independent implementations have to agree on it exactly, and gitignore's
/// per-directory cascade and its negation corners are where independent
/// implementations drift. One `.okfignore`, at the bundle root, no cascade.
fn glob_rx(g: &str) -> String {
    let c: Vec<char> = g.chars().collect();
    let mut out: Vec<String> = Vec::with_capacity(c.len());
    let mut i = 0usize;
    while i < c.len() {
        let ch = c[i];
        if ch == '*' && i + 1 < c.len() && c[i + 1] == '*' {
            // `/**/` matches a single `/` as well as any run of directories, so
            // `a/**/b` matches `a/b`. Without this the pattern everyone writes
            // first silently matches nothing at the one depth they meant.
            if i > 0 && c[i - 1] == '/' && i + 2 < c.len() && c[i + 2] == '/' {
                let n = out.len();
                out[n - 1] = "(?:/.*)?/".to_string();
                i += 3;
            } else {
                out.push(".*".to_string());
                i += 2;
            }
        } else if ch == '*' {
            out.push("[^/]*".to_string());
            i += 1;
        } else if ch == '?' {
            out.push("[^/]".to_string());
            i += 1;
        } else {
            if GLOB_META.contains(&ch) {
                out.push(format!("\\{}", ch));
            } else {
                out.push(ch.to_string());
            }
            i += 1;
        }
    }
    format!("^{}$", out.concat())
}

/// Parse a bundle's `.okfignore` into match rules; empty when the file is
/// absent, which is what makes this a pure addition — a bundle without one
/// reads exactly as it did before.
pub fn rules(root: &Path) -> Vec<Rule> {
    let text = match std::fs::read_to_string(root.join(IGNORE_FILE)) {
        Ok(t) => t,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    for ln in text.lines() {
        let mut p = ln.trim();
        if p.is_empty() || p.starts_with('#') {
            continue;
        }
        let neg = p.starts_with('!');
        if neg {
            p = p[1..].trim();
        }
        if p.is_empty() {
            continue;
        }
        let dir_only = p.ends_with('/');
        if dir_only {
            p = &p[..p.len() - 1];
        }
        if p.is_empty() {
            continue;
        }
        if let Ok(rx) = Regex::new(&glob_rx(p)) {
            out.push(Rule {
                rx,
                neg,
                dir_only,
                anchored: p.contains('/'),
            });
        }
    }
    out
}

/// True when `path` (bundle-relative, forward slashes) is ignored. The LAST
/// matching rule decides, so a `!` line can re-include a file an earlier
/// pattern swept up.
pub fn is_ignored(path: &str, rules: &[Rule]) -> bool {
    if rules.is_empty() {
        return false;
    }
    let base = path.rsplit('/').next().unwrap_or(path);
    // SPEC 3.1 reserves these two. A bundle that could ignore its own index
    // would lose its `okf_version` and its directory listing, so they are never
    // ignorable: an ignore file cannot un-structure the bundle.
    if RESERVED.contains(&base) {
        return false;
    }
    let parts: Vec<&str> = path.split('/').collect();
    let dirs = &parts[..parts.len() - 1];
    let pref: Vec<String> = (0..dirs.len()).map(|k| dirs[..=k].join("/")).collect();
    let mut out = false;
    for r in rules {
        let hit = if r.dir_only {
            if r.anchored {
                pref.iter().any(|s| r.rx.is_match(s))
            } else {
                dirs.iter().any(|s| r.rx.is_match(s))
            }
        } else if r.anchored {
            r.rx.is_match(path)
        } else {
            r.rx.is_match(base)
        };
        if hit {
            out = !r.neg;
        }
    }
    out
}
