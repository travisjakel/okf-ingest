// `.okfignore` — a producer's declaration that some `.md` files in its tree
// are not concept documents.
//
// SPEC 3.1 reserves exactly two filenames and then says "All other `.md` files
// are concept documents", which leaves a bundle no way to say that its README,
// its schema.md, or a vendored deployment doc was never a concept. Every one of
// them fails the hard `type:` rule, so a conformant bundle is unreachable for
// any repository that is also a repository. The alternative "fix" is to put
// `type: Doc` on a README, which is a lie told to a validator.
//
// An ignored file leaves the CONCEPT set and stays in the FILE set, so it is
// exactly what it always was: an ordinary file in the tree. A reference to it
// resolves as non_concept_target (info, SPEC 6.2/6.3) instead of as a broken
// link, and nothing about the catalog schema changes.
//
// Mirrors r/okf/R/okf.R and py/okf/okf.py; the grammar is locked across all
// five bindings by conformance/bundles/okfignore.

#include "okf.hpp"

#include <filesystem>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace okf {

namespace {

// Characters escaped to stay literal in every binding's regex engine.
// Everything else — `/`, `-`, `_`, alphanumerics, any non-ASCII — passes
// through UNESCAPED, because Rust's regex crate REJECTS an unrecognized escape
// where std::regex and PCRE accept it. Escaping only the true metacharacters is
// the one rule all five agree on.
const std::string GLOB_META = ".\\+*?()[]{}^$|";

// Trim ASCII whitespace from both ends.
std::string trim(const std::string& s) {
    std::size_t a = s.find_first_not_of(" \t\r\n\f\v");
    if (a == std::string::npos) return "";
    std::size_t b = s.find_last_not_of(" \t\r\n\f\v");
    return s.substr(a, b - a + 1);
}

}  // namespace

// Translate one .okfignore pattern into a fully anchored regex.
//
// A deliberately small, completely specified subset of gitignore: five
// independent implementations have to agree on it exactly, and gitignore's
// per-directory cascade and its negation corners are where independent
// implementations drift. One .okfignore, at the bundle root, no cascade.
std::string glob_rx(const std::string& g) {
    std::vector<std::string> out;
    std::size_t i = 0, n = g.size();
    while (i < n) {
        char ch = g[i];
        if (ch == '*' && i + 1 < n && g[i + 1] == '*') {
            // `/**/` matches a single `/` as well as any run of directories, so
            // `a/**/b` matches `a/b`. Without this the pattern everyone writes
            // first silently matches nothing at the one depth they meant.
            if (i > 0 && g[i - 1] == '/' && i + 2 < n && g[i + 2] == '/') {
                out.back() = "(?:/.*)?/";
                i += 3;
            } else {
                out.push_back(".*");
                i += 2;
            }
        } else if (ch == '*') {
            out.push_back("[^/]*");
            ++i;
        } else if (ch == '?') {
            out.push_back("[^/]");
            ++i;
        } else {
            if (GLOB_META.find(ch) != std::string::npos) {
                out.push_back(std::string("\\") + ch);
            } else {
                out.push_back(std::string(1, ch));
            }
            ++i;
        }
    }
    std::string body;
    for (const std::string& p : out) body += p;
    return "^" + body + "$";
}

// Parse a bundle's .okfignore into match rules; empty when the file is absent,
// which is what makes this a pure addition — a bundle without one reads exactly
// as it did before.
std::vector<IgnoreRule> ignore_rules(const std::string& root) {
    std::vector<IgnoreRule> out;
    std::ifstream in(fs::path(root) / IGNORE_FILE, std::ios::binary);
    if (!in) return out;
    std::string ln;
    while (std::getline(in, ln)) {
        std::string p = trim(ln);
        if (p.empty() || p[0] == '#') continue;
        bool neg = p[0] == '!';
        if (neg) p = trim(p.substr(1));
        if (p.empty()) continue;
        bool dir_only = p.back() == '/';
        if (dir_only) p.pop_back();
        if (p.empty()) continue;
        IgnoreRule r;
        r.rx = std::regex(glob_rx(p), std::regex::ECMAScript);
        r.neg = neg;
        r.dir_only = dir_only;
        r.anchored = p.find('/') != std::string::npos;
        out.push_back(std::move(r));
    }
    return out;
}

// True when `path` (bundle-relative, forward slashes) is ignored. The LAST
// matching rule decides, so a `!` line can re-include a file an earlier pattern
// swept up.
bool is_ignored(const std::string& path, const std::vector<IgnoreRule>& rules) {
    if (rules.empty()) return false;
    std::size_t slash = path.rfind('/');
    std::string base = slash == std::string::npos ? path : path.substr(slash + 1);
    // SPEC 3.1 reserves these two. A bundle that could ignore its own index
    // would lose its okf_version and its directory listing, so they are never
    // ignorable: an ignore file cannot un-structure the bundle.
    if (RESERVED.count(base) > 0) return false;

    std::vector<std::string> dirs, pref;
    std::stringstream ss(path);
    std::string part;
    while (std::getline(ss, part, '/')) dirs.push_back(part);
    if (!dirs.empty()) dirs.pop_back();  // drop the filename
    std::string acc;
    for (const std::string& d : dirs) {
        acc = acc.empty() ? d : acc + "/" + d;
        pref.push_back(acc);
    }

    bool out = false;
    for (const IgnoreRule& r : rules) {
        bool hit = false;
        if (r.dir_only) {
            const std::vector<std::string>& subj = r.anchored ? pref : dirs;
            for (const std::string& s : subj) {
                if (std::regex_match(s, r.rx)) { hit = true; break; }
            }
        } else {
            hit = std::regex_match(r.anchored ? path : base, r.rx);
        }
        if (hit) out = !r.neg;
    }
    return out;
}

}  // namespace okf
