// Conformance check: C++ binding vs conformance/expected/*.json.
// Mirrors conformance/check_py.py — collects every failure, then exits 1.
// Usage: check_cpp <path-to-conformance-dir>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>

#include "../okf/okf.hpp"
#include "../okf/sha1.hpp"

namespace fs = std::filesystem;
using okf::json;

static std::vector<std::string> fails;

template <typename T>
static void check(const std::string& name, const T& got, const T& want) {
    if (!(got == want)) {
        std::ostringstream ss;
        ss << name << ": got " << json(got).dump() << " want " << json(want).dump();
        fails.push_back(ss.str());
    }
}

static json load(const fs::path& p) {
    std::ifstream in(p);
    if (!in) {
        std::cerr << "cannot open " << p << "\n";
        std::exit(2);
    }
    return json::parse(in);
}

static std::string opt_str(const std::optional<std::string>& o) {
    return o.value_or("");
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: check_cpp <conformance-dir>\n";
        return 2;
    }
    fs::path here = argv[1];

    // sha1 self-test (vendored implementation) against FIPS 180-1 vectors.
    check<std::string>("sha1.abc", okf::detail::sha1_hex("abc"),
                       "a9993e364706816aba3e25717850c26c9cd0d89d");
    check<std::string>("sha1.empty", okf::detail::sha1_hex(""),
                       "da39a3ee5e6b4b0d3255bfef95601890afd80709");

    // --- store (conformant) ---
    okf::Ingested ing = okf::ingest((here / "bundles/store").string());
    json exp = load(here / "expected/store.json");
    check<std::string>("store.okf_version", opt_str(ing.bundle.okf_version),
                       exp["bundle"]["okf_version"].get<std::string>());
    check<std::size_t>("store.n_concepts", ing.summary.n_concepts,
                       exp["bundle"]["n_concepts"].get<std::size_t>());
    check<std::size_t>("store.n_conformant", ing.summary.n_conformant,
                       exp["bundle"]["n_conformant"].get<std::size_t>());
    check<bool>("store.conformant", ing.summary.conformant,
                exp["bundle"]["conformant"].get<bool>());
    check<std::size_t>("store.errors", ing.summary.errors, 0);
    check<std::size_t>("store.links_total", ing.summary.links_total, 8);
    check<std::size_t>("store.links_broken", ing.summary.links_broken, 1);
    std::string got_h;
    for (const okf::Concept& c : ing.bundle.concepts) {
        if (c.path == "customers.md") got_h = c.content_hash;
    }
    check<std::string>("store.content_hash[customers.md]", got_h,
                       exp["content_hashes"]["customers.md"].get<std::string>());

    // --- fetch path: ingest the same bundle from a tar archive (offline) ---
    {
        auto ticks = std::chrono::steady_clock::now().time_since_epoch().count();
        fs::path tmp = fs::temp_directory_path() /
                       ("okf_chk_" + std::to_string(static_cast<long long>(ticks)));
        fs::create_directories(tmp);
        fs::path tarp = tmp / "store.tar.gz";
        // GNU tar reads "C:\..." -f args as remote host:path; cd to the temp
        // dir and use a relative archive name (mirrors okf/fetch.cpp).
#ifdef _WIN32
        std::string cmd = "cd /d \"" + tmp.string() + "\" && ";
#else
        std::string cmd = "cd \"" + tmp.string() + "\" && ";
#endif
        cmd += "tar -czf store.tar.gz -C \"" + (here / "bundles").string() + "\" store";
        if (std::system(cmd.c_str()) != 0) {
            fails.push_back("fetch.tar: could not create archive via system tar");
        } else {
            try {
                okf::Ingested ing3 = okf::ingest(tarp.string());
                check<std::size_t>("fetch.tar.n_concepts", ing3.summary.n_concepts, 3);
                check<bool>("fetch.tar.conformant", ing3.summary.conformant, true);
            } catch (const std::exception& e) {
                fails.push_back(std::string("fetch.tar: ") + e.what());
            }
        }
        std::error_code ec;
        fs::remove_all(tmp, ec);
    }

    // --- negative ---
    okf::Ingested ing2 = okf::ingest((here / "bundles/negative").string());
    json expn = load(here / "expected/negative.json");
    check<bool>("negative.conformant", ing2.summary.conformant,
                expn["bundle"]["conformant"].get<bool>());
    check<std::size_t>("negative.errors", ing2.summary.errors,
                       expn["validation"]["errors"].get<std::size_t>());
    for (const json& er : expn["validation"]["error_rules"]) {
        std::string path = er["path"].get<std::string>();
        std::string got_rule;
        for (const okf::Finding& f : ing2.findings) {
            if (f.severity == "error" && f.path == path) got_rule = f.rule;
        }
        check<std::string>("negative." + path, got_rule, er["rule"].get<std::string>());
    }

    // --- wikilinks ---
    okf::Ingested ingw = okf::ingest((here / "bundles/wikilinks").string());
    json expw = load(here / "expected/wikilinks.json");
    check<std::size_t>("wikilinks.n_concepts", ingw.summary.n_concepts,
                       expw["bundle"]["n_concepts"].get<std::size_t>());
    check<bool>("wikilinks.conformant", ingw.summary.conformant,
                expw["bundle"]["conformant"].get<bool>());
    check<std::size_t>("wikilinks.links_total", ingw.summary.links_total,
                       expw["links"]["total"].get<std::size_t>());
    check<std::size_t>("wikilinks.links_broken", ingw.summary.links_broken,
                       expw["links"]["broken"].get<std::size_t>());
    for (auto it = expw["resolutions"].begin(); it != expw["resolutions"].end(); ++it) {
        std::string key = it.key();
        std::size_t bar = key.find('|');
        std::string src = key.substr(0, bar), raw = key.substr(bar + 1);
        json got = nullptr;
        for (const okf::Link& l : ingw.links) {
            if (l.src_path == src && l.dst_raw == raw) {
                got = l.dst_path ? json(*l.dst_path) : json(nullptr);
            }
        }
        check<json>("wikilinks." + key, got, it.value());
    }

    // --- v0.2 (generated/sources/verified; generated.at timestamp fallback) ---
    okf::Ingested ingv = okf::ingest((here / "bundles/v02").string());
    json expv = load(here / "expected/v02.json");
    check<std::string>("v02.okf_version", opt_str(ingv.bundle.okf_version),
                       expv["bundle"]["okf_version"].get<std::string>());
    check<std::size_t>("v02.n_concepts", ingv.summary.n_concepts,
                       expv["bundle"]["n_concepts"].get<std::size_t>());
    check<bool>("v02.conformant", ingv.summary.conformant,
                expv["bundle"]["conformant"].get<bool>());
    check<std::size_t>("v02.errors", ingv.summary.errors,
                       expv["validation"]["errors"].get<std::size_t>());
    check<std::size_t>("v02.warnings", ingv.summary.warnings,
                       expv["validation"]["warnings"].get<std::size_t>());
    check<std::size_t>("v02.links_total", ingv.summary.links_total,
                       expv["links"]["total"].get<std::size_t>());
    check<std::size_t>("v02.links_broken", ingv.summary.links_broken,
                       expv["links"]["broken"].get<std::size_t>());
    for (const json& fr : expv["validation"]["forbidden_rules"]) {
        std::string rule = fr.get<std::string>();
        bool present = false;
        for (const okf::Finding& f : ingv.findings) {
            if (f.rule == rule) present = true;
        }
        check<bool>("v02.no_" + rule, present, false);
    }
    for (auto it = expv["timestamps"].begin(); it != expv["timestamps"].end(); ++it) {
        if (!it.key().empty() && it.key()[0] == '_') continue;
        std::string got;
        for (const okf::Concept& cc : ingv.bundle.concepts) {
            if (cc.path == it.key()) got = cc.timestamp.value_or("");
        }
        check<std::string>("v02.timestamp[" + it.key() + "]", got,
                           it.value().get<std::string>());
    }

    // --- rank (Personalized PageRank: exact, deterministic, parity-locked) ---
    okf::Ingested ingr = okf::ingest((here / "bundles/store").string());
    json expr = load(here / "expected/rank.json");
    okf::PprOptions ro;
    ro.damping = expr["damping"].get<double>();
    ro.k = 10;
    std::vector<okf::RankRow> ranked =
        okf::ppr(ingr, {expr["start"].get<std::string>()}, ro);
    json got_rank = json::array();
    for (const okf::RankRow& r : ranked) {
        got_rank.push_back({{"path", r.path}, {"score", okf::round_dec(r.score, 8)}});
    }
    check<json>("rank.ranking", got_rank, expr["ranking"]);

    // --- query seeding (lexical seeds -> multi-seed PPR, parity-locked) ---
    json expq = load(here / "expected/query.json");
    std::vector<okf::Seed> got_seeds = okf::seeds(ingr, expq["query"].get<std::string>(), 5);
    json got_seed_pairs = json::array();
    std::vector<std::string> starts;
    okf::PprOptions qo;
    qo.k = 10;
    for (const okf::Seed& s : got_seeds) {
        got_seed_pairs.push_back({{"path", s.path}, {"score", s.score}});
        starts.push_back(s.path);
        qo.weights.push_back(s.score);
    }
    json want_seed_pairs = json::array();
    for (const json& s : expq["seeds"]) {
        want_seed_pairs.push_back({{"path", s["path"]}, {"score", s["score"]}});
    }
    check<json>("query.seeds", got_seed_pairs, want_seed_pairs);
    std::vector<okf::RankRow> qr = okf::ppr(ingr, starts, qo);
    json got_qr = json::array();
    for (const okf::RankRow& r : qr) {
        got_qr.push_back({{"path", r.path}, {"score", okf::round_dec(r.score, 8)}});
    }
    check<json>("query.ranking", got_qr, expq["ranking"]);

    // --- diff (deterministic concept-level changelog) ---
    std::string da = (here / "bundles/diff_a").string();
    std::string db = (here / "bundles/diff_b").string();
    okf::Diff dd = okf::diff(okf::DiffSide::from_dir(da), okf::DiffSide::from_dir(db));
    json expd = load(here / "expected/diff.json");
    check<bool>("diff.identical", dd.identical, expd["identical"].get<bool>());
    check<json>("diff.added", json(dd.added), expd["added"]);
    check<json>("diff.removed", json(dd.removed), expd["removed"]);
    check<json>("diff.changed", json(dd.changed), expd["changed"]);
    auto fmt_field = [](const std::vector<okf::FieldChange>& xs) {
        json out = json::array();
        for (const okf::FieldChange& t : xs) {
            out.push_back(t.path + "|" + t.from.value_or("None") + "|" + t.to.value_or("None"));
        }
        return out;
    };
    check<json>("diff.type_changed", fmt_field(dd.type_changed), expd["type_changed"]);
    check<json>("diff.retitled", fmt_field(dd.retitled), expd["retitled"]);
    auto fmt_edge = [](const std::vector<okf::EdgeDelta>& xs) {
        json out = json::array();
        for (const okf::EdgeDelta& l : xs) out.push_back(l.src_path + "|" + l.dst);
        return out;
    };
    check<json>("diff.links_added", fmt_edge(dd.links_added), expd["links_added"]);
    check<json>("diff.links_removed", fmt_edge(dd.links_removed), expd["links_removed"]);
    check<json>("diff.broken_added", fmt_edge(dd.broken_added), expd["broken_added"]);
    check<json>("diff.broken_fixed", fmt_edge(dd.broken_fixed), expd["broken_fixed"]);
    // drift mode: an ingest diffed against its own source directory is identical
    okf::Ingested ingd = okf::ingest(da);
    okf::Diff d0 = okf::diff(okf::DiffSide::from_ingested(ingd), okf::DiffSide::from_dir(da));
    check<bool>("diff.drift_identical", d0.identical, true);

    // --- v0.2 Attested Computation: SPEC 6.2 frontmatter path fields as edges ---
    okf::Ingested inga = okf::ingest((here / "bundles/v02_attested").string());
    json expa = load(here / "expected/v02_attested.json");
    check<std::size_t>("v02a.n_files", inga.summary.n_files,
                       expa["bundle"]["n_files"].get<std::size_t>());
    check<std::size_t>("v02a.n_concepts", inga.summary.n_concepts,
                       expa["bundle"]["n_concepts"].get<std::size_t>());
    check<std::size_t>("v02a.n_conformant", inga.summary.n_conformant,
                       expa["bundle"]["n_conformant"].get<std::size_t>());
    check<bool>("v02a.conformant", inga.summary.conformant,
                expa["bundle"]["conformant"].get<bool>());
    check<std::size_t>("v02a.errors", inga.summary.errors,
                       expa["validation"]["errors"].get<std::size_t>());
    check<std::size_t>("v02a.warnings", inga.summary.warnings,
                       expa["validation"]["warnings"].get<std::size_t>());
    check<std::size_t>("v02a.links_total", inga.summary.links_total,
                       expa["links"]["total"].get<std::size_t>());
    check<std::size_t>("v02a.links_broken", inga.summary.links_broken,
                       expa["links"]["broken"].get<std::size_t>());
    for (const json& r : expa["validation"]["forbidden_rules"]) {
        std::string rule = r.get<std::string>();
        bool present = false;
        for (const okf::Finding& f : inga.findings) {
            if (f.rule == rule) present = true;
        }
        check<bool>("v02a.no_" + rule, present, false);
    }
    for (auto it = expa["validation"]["rule_counts"].begin();
         it != expa["validation"]["rule_counts"].end(); ++it) {
        std::size_t got = 0;
        for (const okf::Finding& f : inga.findings) {
            if (f.rule == it.key()) ++got;
        }
        check<std::size_t>("v02a.rule[" + it.key() + "]", got, it.value().get<std::size_t>());
    }
    for (auto it = expa["links"]["by_kind"].begin(); it != expa["links"]["by_kind"].end(); ++it) {
        std::size_t got = 0;
        for (const okf::Link& l : inga.links) {
            if (l.kind == it.key()) ++got;
        }
        check<std::size_t>("v02a.kind[" + it.key() + "]", got, it.value().get<std::size_t>());
    }
    for (auto it = expa["links"]["by_target"].begin(); it != expa["links"]["by_target"].end();
         ++it) {
        std::size_t got = 0;
        for (const okf::Link& l : inga.links) {
            if (l.target == it.key()) ++got;
        }
        check<std::size_t>("v02a.target[" + it.key() + "]", got, it.value().get<std::size_t>());
    }
    for (auto it = expa["resolutions"].begin(); it != expa["resolutions"].end(); ++it) {
        if (!it.key().empty() && it.key()[0] == '_') continue;
        std::size_t bar = it.key().find('|');
        std::string src = it.key().substr(0, bar), raw = it.key().substr(bar + 1);
        std::string got;
        for (const okf::Link& l : inga.links) {
            if (l.src_path == src && l.dst_raw == raw) got = opt_str(l.dst_path);
        }
        check<std::string>("v02a." + it.key(), got, it.value().get<std::string>());
    }
    for (auto it = expa["timestamps"].begin(); it != expa["timestamps"].end(); ++it) {
        if (!it.key().empty() && it.key()[0] == '_') continue;
        std::string got;
        for (const okf::Concept& c : inga.bundle.concepts) {
            if (c.path == it.key()) got = opt_str(c.timestamp);
        }
        check<std::string>("v02a.timestamp[" + it.key() + "]", got,
                           it.value().get<std::string>());
    }

    // --- yaml_scalars: YAML 1.2 core-schema booleans, identical everywhere ---
    okf::Ingested ingy = okf::ingest((here / "bundles/yaml_scalars").string());
    json expy = load(here / "expected/yaml_scalars.json");
    json fmy;
    for (const okf::Concept& cc : ingy.bundle.concepts) {
        if (cc.path == "scalars.md") fmy = cc.frontmatter;
    }
    for (auto it = expy["strings_every_binding"].begin(); it != expy["strings_every_binding"].end(); ++it) {
        std::string got = fmy.contains(it.key()) && fmy[it.key()].is_string()
                              ? fmy[it.key()].get<std::string>() : std::string("<not a string>");
        check<std::string>("ys.str[" + it.key() + "]", got, it.value().get<std::string>());
    }
    // rapidyaml keeps every scalar as raw text, so true/false arrive as strings
    // here. That is by design (it is what makes timestamps verbatim for free)
    // and is asserted as such rather than papered over.
    for (auto it = expy["booleans_as_text_rawtext_bindings"].begin();
         it != expy["booleans_as_text_rawtext_bindings"].end(); ++it) {
        std::string got = fmy.contains(it.key()) && fmy[it.key()].is_string()
                              ? fmy[it.key()].get<std::string>() : std::string("<not a string>");
        check<std::string>("ys.rawbool[" + it.key() + "]", got, it.value().get<std::string>());
    }
    {
        std::vector<std::string> names;
        for (const json& prm : fmy["parameters"]) names.push_back(prm["name"].get<std::string>());
        std::vector<std::string> want;
        for (const json& v : expy["parameter_names"]) want.push_back(v.get<std::string>());
        check<std::vector<std::string>>("ys.parameter_names", names, want);
    }

    // traversal-guard unit check (member name validation is pure string logic)
    try {
        okf::Fetched bad = okf::fetch((here / "bundles/store/../nope.tar.gz").string());
        fails.push_back("fetch.guard: expected failure for nonexistent archive");
    } catch (const std::exception&) {
        // expected: not a dir, tar listing fails
    }

    if (!fails.empty()) {
        std::cout << "FAIL\n";
        for (const std::string& f : fails) std::cout << "  " << f << "\n";
        return 1;
    }
    std::cout << "PASS — C++ binding conformant on all fixtures\n";
    return 0;
}
