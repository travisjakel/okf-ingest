// okf — Open Knowledge Format ingestion (C++ binding).
//
// The fixture-locked core, byte-identical with the R / Python / Rust bindings
// on the shared conformance fixtures (conformance/): frontmatter parsing +
// body normalization (content_hash), markdown-link and [[wikilink]]
// extraction/resolution, OKF validation, ingest summaries, exact
// Personalized-PageRank ranking, lexical query seeding, concept-level diff,
// and bundle fetch (dir / tar via the system `tar` / git subprocess).
//
// Out of scope by design (use the R or Python binding): HTML render, doctor,
// graph exports, RAG/embeddings, CLI, DuckDB catalog, zip + remote-archive
// fetch. Every conformance-asserted value is available on the in-memory
// Ingested struct.
#pragma once

#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

namespace okf {

using json = nlohmann::json;

inline const std::set<std::string> RESERVED = {"index.md", "log.md"};

struct OkfError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// ---- model ----------------------------------------------------------------

struct Concept {
    std::string path;  // bundle-relative, forward slashes
    bool reserved = false;
    std::optional<std::string> type, title, description, resource;
    json tags = nullptr;  // JSON-shaped; serialized text is what seeds match
    std::optional<std::string> timestamp;  // verbatim string, never coerced
    std::string body;
    json frontmatter = nullptr;  // object, or null when unparseable
    // "no_frontmatter" | "unclosed_frontmatter" | "yaml_parse_error"
    std::optional<std::string> parse_error;
    std::vector<std::string> links_raw, wikilinks_raw;
    std::string content_hash;  // sha1 hex of the normalized body
};

struct Bundle {
    std::string bundle_id, root;
    std::optional<std::string> okf_version;
    std::string source_kind = "dir";  // dir | git | tar
    std::vector<Concept> concepts;    // sorted by path (byte order)
    std::set<std::string> known;
    // Every file in the tree, not only concepts: SPEC 6.2 path-valued fields
    // and SPEC 6.3 references/ point at non-markdown artifacts (an attester
    // .py, a computation .sql). Those are real targets, not broken links.
    std::set<std::string> files;
};

struct Link {
    std::string src_path, dst_raw;
    std::optional<std::string> dst_path;
    bool resolved = false;
    // body | wikilink | resource | source | computation | executor | attester
    std::string kind;
    // concept | file | scope | missing
    std::string target;
};

struct Finding {
    // severity: "error" | "warn" | "info"
    std::string path, severity, rule, message;
};

struct Summary {
    std::size_t n_files = 0, n_concepts = 0, n_conformant = 0;
    bool conformant = false;
    std::size_t errors = 0, warnings = 0, links_total = 0, links_broken = 0;
};

// The in-memory "catalog": everything the conformance contract reads back.
struct Ingested {
    Bundle bundle;
    std::vector<Link> links;
    std::vector<Finding> findings;
    Summary summary;
};

// ---- parse ----------------------------------------------------------------

struct Parsed {
    json meta = nullptr;  // object, or null
    std::string body;
    std::optional<std::string> parse_error;
};

// Frontmatter + body from raw text (splitlines-style normalization).
Parsed parse_text(const std::string& text);
// sha1 hex of the normalized body (cross-language parity lock).
std::string content_hash(const std::string& body);

// ---- links ----------------------------------------------------------------

std::vector<std::string> extract_links(const std::string& body);
std::vector<std::string> extract_wikilinks(const std::string& body);
std::vector<Link> links(const Bundle& b);
// Path-valued frontmatter fields (SPEC 6.2), in a fixed order: (kind, raw).
std::vector<std::pair<std::string, std::string>> fm_paths(const json& fm);
// A sources[].resource MAY be a scope descriptor, not a path (SPEC 5.1).
bool is_scope(const std::string& raw);
// SPEC 6.2 resolution, then a bundle-root fallback. Returns (path, how) where
// how is "spec" or "root"; nullopt when nothing resolves.
std::optional<std::pair<std::string, std::string>> resolve_path(
    const std::string& raw, const std::string& src_rel, const std::set<std::string>& targets);

// ---- validate / read / ingest --------------------------------------------

std::vector<Finding> validate(const Bundle& b);
Bundle read_bundle(const std::string& root, const std::string& source_kind = "dir");
Ingested ingest_bundle(Bundle b);
// Source: bundle directory, local tar archive, or git URL.
Ingested ingest(const std::string& source);

// ---- graph ----------------------------------------------------------------

struct Seed {
    std::string path;
    double score = 0.0;
    std::optional<std::string> title;
};

struct RankRow {
    std::string path;
    double score = 0.0;
    std::optional<std::string> title;
    bool reserved = false;
};

struct PprOptions {
    double damping = 0.85, tol = 1e-12;
    int max_iter = 200;
    int k = 20;  // <= 0: return all positive-score rows
    std::vector<double> weights;  // empty: 1.0 per start
};

// Decimal round-half-even (Python round()) via fixed-precision formatting.
double round_dec(double x, int digits);
std::vector<Seed> seeds(const Ingested& ing, const std::string& query, std::size_t k = 5);
std::vector<RankRow> ppr(const Ingested& ing, const std::vector<std::string>& starts,
                         const PprOptions& opts = {});

// ---- diff -----------------------------------------------------------------

struct FieldChange {
    std::string path;
    std::optional<std::string> from, to;
};

struct EdgeDelta {
    std::string src_path, dst;  // dst = dst_path (edges) or dst_raw (broken)
};

struct Diff {
    bool identical = false;
    std::vector<std::string> added, removed, changed;
    std::vector<FieldChange> type_changed, retitled;
    std::vector<EdgeDelta> links_added, links_removed, broken_added, broken_fixed;
};

// One side of a diff: a bundle directory path, a Bundle, or an Ingested
// (the latter is drift mode — "what changed since this ingest").
struct DiffSide {
    const std::string* dir = nullptr;
    const Bundle* bundle = nullptr;
    const Ingested* ingested = nullptr;
    static DiffSide from_dir(const std::string& d) { return {&d, nullptr, nullptr}; }
    static DiffSide from_bundle(const Bundle& b) { return {nullptr, &b, nullptr}; }
    static DiffSide from_ingested(const Ingested& i) { return {nullptr, nullptr, &i}; }
};

Diff diff(const DiffSide& a, const DiffSide& b);

// ---- fetch ----------------------------------------------------------------

struct Fetched {
    std::string dir, kind;
    std::string tmp;  // temp root to remove when done ("" = none)
    Fetched() = default;
    Fetched(const Fetched&) = delete;
    Fetched& operator=(const Fetched&) = delete;
    Fetched(Fetched&& o) noexcept { *this = std::move(o); }
    Fetched& operator=(Fetched&& o) noexcept {
        dir = std::move(o.dir); kind = std::move(o.kind); tmp = std::move(o.tmp);
        o.tmp.clear();
        return *this;
    }
    ~Fetched();  // removes tmp (the Python binding's cleanup())
};

Fetched fetch(const std::string& source, const std::string& subdir = "",
              const std::string& branch = "");

}  // namespace okf
