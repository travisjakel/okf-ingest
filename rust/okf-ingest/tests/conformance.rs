//! Conformance check: Rust binding vs conformance/expected/*.json.
//! Mirrors conformance/check_py.py — collects every failure, then asserts.
//! Run: cargo test --test conformance

use std::fmt::Debug;
use std::fs::File;
use std::path::{Path, PathBuf};

use okf_ingest::{diff, ingest, ppr, round_dec, seeds, DiffSide, PprOptions, Severity};
use serde_json::Value;

fn here() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../conformance")
}

fn load(rel: &str) -> Value {
    let p = here().join(rel);
    let f = File::open(&p).unwrap_or_else(|e| panic!("cannot open {}: {e}", p.display()));
    serde_json::from_reader(f).unwrap_or_else(|e| panic!("bad JSON {}: {e}", p.display()))
}

#[derive(Default)]
struct Checker {
    fails: Vec<String>,
}

impl Checker {
    fn check<T: PartialEq + Debug>(&mut self, name: &str, got: T, want: T) {
        if got != want {
            self.fails
                .push(format!("{name}: got {got:?} want {want:?}"));
        }
    }
}

#[test]
fn conformance() {
    let here = here();
    let mut c = Checker::default();

    // --- store (conformant) ---
    let ing = ingest(here.join("bundles/store").to_str().unwrap()).unwrap();
    let exp = load("expected/store.json");
    let expb = &exp["bundle"];
    c.check(
        "store.okf_version",
        ing.bundle.okf_version.clone().unwrap_or_default(),
        expb["okf_version"].as_str().unwrap().to_string(),
    );
    c.check(
        "store.n_concepts",
        ing.summary.n_concepts as u64,
        expb["n_concepts"].as_u64().unwrap(),
    );
    c.check(
        "store.n_conformant",
        ing.summary.n_conformant as u64,
        expb["n_conformant"].as_u64().unwrap(),
    );
    c.check(
        "store.conformant",
        ing.summary.conformant,
        expb["conformant"].as_bool().unwrap(),
    );
    c.check("store.errors", ing.summary.errors, 0);
    c.check("store.links_total", ing.summary.links_total, 8);
    c.check("store.links_broken", ing.summary.links_broken, 1);
    let got_h = ing
        .bundle
        .concepts
        .iter()
        .find(|x| x.path == "customers.md")
        .map(|x| x.content_hash.clone())
        .unwrap_or_default();
    c.check(
        "store.content_hash[customers.md]",
        got_h,
        exp["content_hashes"]["customers.md"]
            .as_str()
            .unwrap()
            .to_string(),
    );

    // --- fetch path: ingest the same bundle from a tar archive (offline) ---
    {
        let tmp = tempfile::tempdir().unwrap();
        let tar_path = tmp.path().join("store.tar.gz");
        let f = File::create(&tar_path).unwrap();
        let enc = flate2::write::GzEncoder::new(f, flate2::Compression::default());
        let mut b = tar::Builder::new(enc);
        b.append_dir_all("store", here.join("bundles/store"))
            .unwrap();
        b.into_inner().unwrap().finish().unwrap();
        let ing3 = ingest(tar_path.to_str().unwrap()).unwrap();
        c.check("fetch.tar.n_concepts", ing3.summary.n_concepts, 3);
        c.check("fetch.tar.conformant", ing3.summary.conformant, true);
    }

    // --- negative ---
    let ing2 = ingest(here.join("bundles/negative").to_str().unwrap()).unwrap();
    let expn = load("expected/negative.json");
    c.check(
        "negative.conformant",
        ing2.summary.conformant,
        expn["bundle"]["conformant"].as_bool().unwrap(),
    );
    c.check(
        "negative.errors",
        ing2.summary.errors as u64,
        expn["validation"]["errors"].as_u64().unwrap(),
    );
    for er in expn["validation"]["error_rules"].as_array().unwrap() {
        let path = er["path"].as_str().unwrap();
        let got_rule = ing2
            .findings
            .iter()
            .find(|f| f.severity == Severity::Error && f.path == path)
            .map(|f| f.rule.clone());
        c.check(
            &format!("negative.{path}"),
            got_rule,
            Some(er["rule"].as_str().unwrap().to_string()),
        );
    }

    // --- wikilinks ---
    let ingw = ingest(here.join("bundles/wikilinks").to_str().unwrap()).unwrap();
    let expw = load("expected/wikilinks.json");
    c.check(
        "wikilinks.n_concepts",
        ingw.summary.n_concepts as u64,
        expw["bundle"]["n_concepts"].as_u64().unwrap(),
    );
    c.check(
        "wikilinks.conformant",
        ingw.summary.conformant,
        expw["bundle"]["conformant"].as_bool().unwrap(),
    );
    c.check(
        "wikilinks.links_total",
        ingw.summary.links_total as u64,
        expw["links"]["total"].as_u64().unwrap(),
    );
    c.check(
        "wikilinks.links_broken",
        ingw.summary.links_broken as u64,
        expw["links"]["broken"].as_u64().unwrap(),
    );
    for (key, want) in expw["resolutions"].as_object().unwrap() {
        let (src, raw) = key.split_once('|').unwrap();
        let got = ingw
            .links
            .iter()
            .find(|l| l.src_path == src && l.dst_raw == raw)
            .map(|l| l.dst_path.clone())
            .unwrap_or(None);
        let want_s = want.as_str().map(str::to_string);
        c.check(&format!("wikilinks.{key}"), got, want_s);
    }

    // --- v0.2 (generated/sources/verified; generated.at timestamp fallback) ---
    let ingv = ingest(here.join("bundles/v02").to_str().unwrap()).unwrap();
    let expv = load("expected/v02.json");
    c.check(
        "v02.okf_version",
        ingv.bundle.okf_version.clone().unwrap_or_default(),
        expv["bundle"]["okf_version"].as_str().unwrap().to_string(),
    );
    c.check(
        "v02.n_concepts",
        ingv.summary.n_concepts as u64,
        expv["bundle"]["n_concepts"].as_u64().unwrap(),
    );
    c.check(
        "v02.conformant",
        ingv.summary.conformant,
        expv["bundle"]["conformant"].as_bool().unwrap(),
    );
    c.check(
        "v02.errors",
        ingv.summary.errors as u64,
        expv["validation"]["errors"].as_u64().unwrap(),
    );
    c.check(
        "v02.warnings",
        ingv.summary.warnings as u64,
        expv["validation"]["warnings"].as_u64().unwrap(),
    );
    c.check(
        "v02.links_total",
        ingv.summary.links_total as u64,
        expv["links"]["total"].as_u64().unwrap(),
    );
    c.check(
        "v02.links_broken",
        ingv.summary.links_broken as u64,
        expv["links"]["broken"].as_u64().unwrap(),
    );
    for fr in expv["validation"]["forbidden_rules"].as_array().unwrap() {
        let fr = fr.as_str().unwrap();
        let present = ingv.findings.iter().any(|f| f.rule == fr);
        c.check(&format!("v02.no_{fr}"), present, false);
    }
    for (pth, want) in expv["timestamps"].as_object().unwrap() {
        if pth.starts_with('_') {
            continue;
        }
        let got = ingv
            .bundle
            .concepts
            .iter()
            .find(|x| &x.path == pth)
            .and_then(|x| x.timestamp.clone());
        c.check(
            &format!("v02.timestamp[{pth}]"),
            got,
            want.as_str().map(str::to_string),
        );
    }

    // --- v0.2 Attested Computation: SPEC 6.2 frontmatter path fields as edges ---
    let inga = ingest(here.join("bundles/v02_attested").to_str().unwrap()).unwrap();
    let expa = load("expected/v02_attested.json");
    for (key, got) in [
        ("n_files", inga.summary.n_files as u64),
        ("n_concepts", inga.summary.n_concepts as u64),
        ("n_conformant", inga.summary.n_conformant as u64),
    ] {
        c.check(
            &format!("v02a.{key}"),
            got,
            expa["bundle"][key].as_u64().unwrap(),
        );
    }
    c.check(
        "v02a.conformant",
        inga.summary.conformant,
        expa["bundle"]["conformant"].as_bool().unwrap(),
    );
    for (key, got) in [
        ("errors", inga.summary.errors as u64),
        ("warnings", inga.summary.warnings as u64),
    ] {
        c.check(
            &format!("v02a.{key}"),
            got,
            expa["validation"][key].as_u64().unwrap(),
        );
    }
    c.check(
        "v02a.links_total",
        inga.summary.links_total as u64,
        expa["links"]["total"].as_u64().unwrap(),
    );
    c.check(
        "v02a.links_broken",
        inga.summary.links_broken as u64,
        expa["links"]["broken"].as_u64().unwrap(),
    );
    for fr in expa["validation"]["forbidden_rules"].as_array().unwrap() {
        let fr = fr.as_str().unwrap();
        let present = inga.findings.iter().any(|f| f.rule == fr);
        c.check(&format!("v02a.no_{fr}"), present, false);
    }
    for (rl, want) in expa["validation"]["rule_counts"].as_object().unwrap() {
        let got = inga.findings.iter().filter(|f| &f.rule == rl).count() as u64;
        c.check(&format!("v02a.rule[{rl}]"), got, want.as_u64().unwrap());
    }
    for (kd, want) in expa["links"]["by_kind"].as_object().unwrap() {
        let got = inga.links.iter().filter(|l| &l.kind == kd).count() as u64;
        c.check(&format!("v02a.kind[{kd}]"), got, want.as_u64().unwrap());
    }
    for (tg, want) in expa["links"]["by_target"].as_object().unwrap() {
        let got = inga.links.iter().filter(|l| &l.target == tg).count() as u64;
        c.check(&format!("v02a.target[{tg}]"), got, want.as_u64().unwrap());
    }
    for (key, want) in expa["resolutions"].as_object().unwrap() {
        if key.starts_with('_') {
            continue;
        }
        let (src, raw) = key.split_once('|').unwrap();
        let got = inga
            .links
            .iter()
            .find(|l| l.src_path == src && l.dst_raw == raw)
            .and_then(|l| l.dst_path.clone());
        c.check(
            &format!("v02a.{key}"),
            got,
            want.as_str().map(str::to_string),
        );
    }
    for (pth, want) in expa["timestamps"].as_object().unwrap() {
        if pth.starts_with('_') {
            continue;
        }
        let got = inga
            .bundle
            .concepts
            .iter()
            .find(|x| &x.path == pth)
            .and_then(|x| x.timestamp.clone());
        c.check(
            &format!("v02a.timestamp[{pth}]"),
            got,
            want.as_str().map(str::to_string),
        );
    }

    // --- yaml_scalars: YAML 1.2 core-schema booleans, identical everywhere ---
    let ingy = ingest(here.join("bundles/yaml_scalars").to_str().unwrap()).unwrap();
    let expy = load("expected/yaml_scalars.json");
    let fmy = ingy
        .bundle
        .concepts
        .iter()
        .find(|c| c.path == "scalars.md")
        .and_then(|c| c.frontmatter.clone())
        .expect("scalars.md frontmatter");
    for (k, want) in expy["strings_every_binding"].as_object().unwrap() {
        c.check(
            &format!("ys.str[{k}]"),
            fmy.get(k).and_then(|v| v.as_str()).map(str::to_string),
            want.as_str().map(str::to_string),
        );
    }
    for (k, want) in expy["integers_typed_bindings"].as_object().unwrap() {
        c.check(
            &format!("ys.int[{k}]"),
            fmy.get(k).and_then(|v| v.as_i64()),
            want.as_i64(),
        );
    }
    for (k, want) in expy["booleans_typed_bindings"].as_object().unwrap() {
        c.check(
            &format!("ys.bool[{k}]"),
            fmy.get(k).and_then(|v| v.as_bool()),
            want.as_bool(),
        );
    }
    let names: Vec<String> = fmy["parameters"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["name"].as_str().unwrap().to_string())
        .collect();
    let want_names: Vec<String> = expy["parameter_names"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    c.check("ys.parameter_names", names, want_names);

    // --- code_fences: references inside fenced code are not extracted ---
    let ingf = ingest(here.join("bundles/code_fences").to_str().unwrap()).unwrap();
    let expf = load("expected/code_fences.json");
    c.check(
        "cf.n_concepts",
        ingf.summary.n_concepts as u64,
        expf["bundle"]["n_concepts"].as_u64().unwrap(),
    );
    c.check(
        "cf.links_total",
        ingf.summary.links_total as u64,
        expf["links"]["total"].as_u64().unwrap(),
    );
    c.check(
        "cf.links_broken",
        ingf.summary.links_broken as u64,
        expf["links"]["broken"].as_u64().unwrap(),
    );
    for bad in expf["must_not_extract"].as_array().unwrap() {
        let bad = bad.as_str().unwrap();
        let present = ingf.links.iter().any(|l| l.dst_raw == bad);
        c.check(&format!("cf.absent[{bad}]"), present, false);
    }
    for (key, want) in expf["must_extract"].as_object().unwrap() {
        if key.starts_with('_') {
            continue;
        }
        let (src, raw) = key.split_once('|').unwrap();
        let got = ingf
            .links
            .iter()
            .find(|l| l.src_path == src && l.dst_raw == raw)
            .and_then(|l| l.dst_path.clone());
        c.check(&format!("cf.{key}"), got, want.as_str().map(str::to_string));
    }

    // --- rank (Personalized PageRank: exact, deterministic, parity-locked) ---
    let ingr = ingest(here.join("bundles/store").to_str().unwrap()).unwrap();
    let expr = load("expected/rank.json");
    let ranked = ppr(
        &ingr,
        &[expr["start"].as_str().unwrap()],
        &PprOptions {
            damping: expr["damping"].as_f64().unwrap(),
            ..Default::default()
        },
    )
    .unwrap();
    let got_rank: Vec<(String, f64)> = ranked
        .iter()
        .take(10)
        .map(|r| (r.path.clone(), round_dec(r.score, 8)))
        .collect();
    let want_rank: Vec<(String, f64)> = expr["ranking"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["path"].as_str().unwrap().to_string(),
                r["score"].as_f64().unwrap(),
            )
        })
        .collect();
    c.check("rank.ranking", got_rank, want_rank);

    // --- query seeding (lexical seeds -> multi-seed PPR, parity-locked) ---
    let expq = load("expected/query.json");
    let got_seeds = seeds(&ingr, expq["query"].as_str().unwrap(), 5);
    let got_seed_pairs: Vec<(String, f64)> = got_seeds
        .iter()
        .map(|s| (s.path.clone(), s.score))
        .collect();
    let want_seed_pairs: Vec<(String, f64)> = expq["seeds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["path"].as_str().unwrap().to_string(),
                r["score"].as_f64().unwrap(),
            )
        })
        .collect();
    c.check("query.seeds", got_seed_pairs, want_seed_pairs);
    let starts: Vec<&str> = got_seeds.iter().map(|s| s.path.as_str()).collect();
    let weights: Vec<f64> = got_seeds.iter().map(|s| s.score).collect();
    let qr = ppr(
        &ingr,
        &starts,
        &PprOptions {
            weights: Some(weights),
            ..Default::default()
        },
    )
    .unwrap();
    let got_qr: Vec<(String, f64)> = qr
        .iter()
        .take(10)
        .map(|r| (r.path.clone(), round_dec(r.score, 8)))
        .collect();
    let want_qr: Vec<(String, f64)> = expq["ranking"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["path"].as_str().unwrap().to_string(),
                r["score"].as_f64().unwrap(),
            )
        })
        .collect();
    c.check("query.ranking", got_qr, want_qr);

    // --- diff (deterministic concept-level changelog) ---
    let da = here.join("bundles/diff_a");
    let db = here.join("bundles/diff_b");
    let dd = diff(DiffSide::Dir(&da), DiffSide::Dir(&db)).unwrap();
    let expd = load("expected/diff.json");
    let want_list = |k: &str| -> Vec<String> {
        expd[k]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect()
    };
    c.check(
        "diff.identical",
        dd.identical,
        expd["identical"].as_bool().unwrap(),
    );
    c.check("diff.added", dd.added.clone(), want_list("added"));
    c.check("diff.removed", dd.removed.clone(), want_list("removed"));
    c.check("diff.changed", dd.changed.clone(), want_list("changed"));
    let fmt_field = |xs: &[okf_ingest::FieldChange]| -> Vec<String> {
        xs.iter()
            .map(|t| {
                format!(
                    "{}|{}|{}",
                    t.path,
                    t.from.as_deref().unwrap_or("None"),
                    t.to.as_deref().unwrap_or("None")
                )
            })
            .collect()
    };
    c.check(
        "diff.type_changed",
        fmt_field(&dd.type_changed),
        want_list("type_changed"),
    );
    c.check(
        "diff.retitled",
        fmt_field(&dd.retitled),
        want_list("retitled"),
    );
    let fmt_edge = |xs: &[okf_ingest::EdgeDelta]| -> Vec<String> {
        xs.iter()
            .map(|l| format!("{}|{}", l.src_path, l.dst))
            .collect()
    };
    c.check(
        "diff.links_added",
        fmt_edge(&dd.links_added),
        want_list("links_added"),
    );
    c.check(
        "diff.links_removed",
        fmt_edge(&dd.links_removed),
        want_list("links_removed"),
    );
    c.check(
        "diff.broken_added",
        fmt_edge(&dd.broken_added),
        want_list("broken_added"),
    );
    c.check(
        "diff.broken_fixed",
        fmt_edge(&dd.broken_fixed),
        want_list("broken_fixed"),
    );
    // drift mode: an ingest diffed against its own source directory is identical
    let ingd = ingest(da.to_str().unwrap()).unwrap();
    let d0 = diff(DiffSide::Ingested(&ingd), DiffSide::Dir(&da)).unwrap();
    c.check("diff.drift_identical", d0.identical, true);

    assert!(c.fails.is_empty(), "FAIL\n  {}", c.fails.join("\n  "));
    println!("PASS — Rust binding conformant on all fixtures");
}
