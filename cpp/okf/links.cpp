// Link extraction + resolution — mirrors py/okf/okf.py (extract_links,
// extract_wikilinks, _wiki_index, resolve_wiki, _norm, resolve_link, links).

#include <algorithm>
#include <cctype>
#include <map>
#include <regex>

#include "okf.hpp"

namespace okf {
namespace {

const std::regex& re_link() {
    static const std::regex re(R"(\]\(\s*([^)\s]+))");
    return re;
}
const std::regex& re_wikilink() {
    static const std::regex re(R"(\[\[([^\]]+)\]\])");
    return re;
}
const std::regex& re_scheme() {
    static const std::regex re(R"(^[a-zA-Z][a-zA-Z0-9+.-]*:)");
    return re;
}

std::string lower_ascii(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

std::string trim(const std::string& s) {
    std::size_t a = s.find_first_not_of(" \t\f\v\r\n");
    if (a == std::string::npos) return "";
    std::size_t b = s.find_last_not_of(" \t\f\v\r\n");
    return s.substr(a, b - a + 1);
}

std::string before_hash(const std::string& s) { return s.substr(0, s.find('#')); }

// str(scalar) on a JSON value from frontmatter (scalars are strings already
// under the rapidyaml mapping; keep a fallback for completeness).
std::string json_scalar_str(const json& v) {
    if (v.is_string()) return v.get<std::string>();
    return v.dump();
}

struct WikiIndex {
    // kind order: id, alias, title, stem (resolution precedence)
    std::map<std::string, std::string> maps[4];
};

void wiki_add(std::map<std::string, std::string>& map, std::set<std::string>& amb,
              const std::string& raw_key, const std::string& path) {
    std::string key = lower_ascii(trim(raw_key));
    if (key.empty()) return;
    auto it = map.find(key);
    if (it != map.end() && it->second != path) amb.insert(key);
    map[key] = path;
}

WikiIndex wiki_index(const std::vector<Concept>& concepts) {
    WikiIndex idx;
    std::set<std::string> amb[4];
    for (const Concept& c : concepts) {
        if (c.frontmatter.is_object()) {
            auto id = c.frontmatter.find("id");
            if (id != c.frontmatter.end() && !id->is_null()) {
                wiki_add(idx.maps[0], amb[0], json_scalar_str(*id), c.path);
            }
            auto aliases = c.frontmatter.find("aliases");
            if (aliases != c.frontmatter.end() && aliases->is_array()) {
                for (const json& a : *aliases) {
                    wiki_add(idx.maps[1], amb[1], json_scalar_str(a), c.path);
                }
            }
        }
        if (c.title && !c.title->empty()) wiki_add(idx.maps[2], amb[2], *c.title, c.path);
        std::size_t slash = c.path.rfind('/');
        std::string base = slash == std::string::npos ? c.path : c.path.substr(slash + 1);
        std::size_t dot = base.rfind('.');
        std::string stem = dot == std::string::npos ? base : base.substr(0, dot);
        wiki_add(idx.maps[3], amb[3], stem, c.path);
    }
    for (int k = 0; k < 4; ++k) {
        for (const std::string& key : amb[k]) idx.maps[k].erase(key);
    }
    return idx;
}

std::optional<std::string> resolve_wiki(const std::string& raw, const WikiIndex& idx,
                                        const std::set<std::string>& known) {
    std::string ref = trim(before_hash(raw));
    if (ref.empty()) return std::nullopt;
    if (known.count(ref)) return ref;
    std::string cand = ref.size() >= 3 && ref.compare(ref.size() - 3, 3, ".md") == 0
                           ? ref
                           : ref + ".md";
    if (known.count(cand)) return cand;
    std::string lref = lower_ascii(ref);
    for (int k = 0; k < 4; ++k) {
        auto it = idx.maps[k].find(lref);
        if (it != idx.maps[k].end()) return it->second;
    }
    return std::nullopt;
}

// Normalize a slash path: drop empty/"." segments, apply "..".
std::string norm(const std::string& p) {
    std::string slashed = p;
    std::replace(slashed.begin(), slashed.end(), '\\', '/');
    std::vector<std::string> out;
    std::size_t start = 0;
    while (start <= slashed.size()) {
        std::size_t sl = slashed.find('/', start);
        std::string seg =
            sl == std::string::npos ? slashed.substr(start) : slashed.substr(start, sl - start);
        if (seg == "..") {
            if (!out.empty()) out.pop_back();
        } else if (!seg.empty() && seg != ".") {
            out.push_back(seg);
        }
        if (sl == std::string::npos) break;
        start = sl + 1;
    }
    std::string joined;
    for (std::size_t i = 0; i < out.size(); ++i) {
        if (i) joined.push_back('/');
        joined += out[i];
    }
    return joined;
}

bool is_external(const std::string& raw) {
    std::string t = before_hash(raw);
    return std::regex_search(t, re_scheme());
}

std::optional<std::string> resolve_link(const std::string& raw, const std::string& src_rel,
                                        const std::set<std::string>& known) {
    std::string t = before_hash(raw);
    std::string cand;
    if (!t.empty() && t[0] == '/') {
        cand = t.substr(1);
    } else {
        std::size_t slash = src_rel.rfind('/');
        cand = slash == std::string::npos ? t : src_rel.substr(0, slash) + "/" + t;
    }
    cand = norm(cand);
    if (known.count(cand)) return cand;
    return std::nullopt;
}

}  // namespace

// Blank out fenced code blocks before extracting references.
//
// Markdown does not linkify fenced content, so neither do we -- but this only
// became consequential with SPEC 10, which makes code in the body the NORMAL
// case for an Attested Computation. Measured on a real runtime: r bundle: R's
// flat[[paste0("knock_on_", src)]] indexing syntax is literally [[...]], so
// three phantom wikilinks came out of one computation. Phantom BROKEN
// references are only noise; the real hazard is a reference in code that
// happens to match a concept, which becomes a silently false edge.
//
// Fenced blocks only. Indented (4-space) blocks are NOT masked -- that is also
// ordinary nested-list continuation. Inline code spans are NOT masked either:
// authors put backticks around a reference for emphasis and mean it, and
// masking spans would have dropped 8 resolving edges in a 219-concept wiki.
//
// Simplified CommonMark, chosen so five bindings implement it identically: a
// line of >=3 backticks or tildes (indented up to 3 spaces) opens; a line of
// >=N of the SAME character with nothing else on it closes. An unclosed fence
// masks to the end of the body.
std::string mask_fences(const std::string& body) {
    std::vector<std::string> out;
    char open_ch = 0;
    std::size_t open_len = 0;
    std::size_t pos = 0;
    while (true) {
        std::size_t nl = body.find('\n', pos);
        std::string line = body.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);

        std::size_t indent = line.find_first_not_of(' ');
        if (indent == std::string::npos) indent = line.size();
        bool handled = false;
        if (indent <= 3 && indent < line.size() &&
            (line[indent] == '`' || line[indent] == '~')) {
            char ch = line[indent];
            std::size_t run = 0;
            while (indent + run < line.size() && line[indent + run] == ch) ++run;
            if (run >= 3) {
                std::string rest = line.substr(indent + run);
                std::string trimmed = trim(rest);
                if (open_ch == 0) {
                    open_ch = ch;
                    open_len = run;
                    out.emplace_back();
                    handled = true;
                } else if (ch == open_ch && run >= open_len && trimmed.empty()) {
                    open_ch = 0;
                    open_len = 0;
                    out.emplace_back();
                    handled = true;
                }
            }
        }
        if (!handled) out.push_back(open_ch != 0 ? std::string() : line);

        if (nl == std::string::npos) break;
        pos = nl + 1;
    }
    std::string joined;
    for (std::size_t i = 0; i < out.size(); ++i) {
        if (i) joined += "\n";
        joined += out[i];
    }
    return joined;
}

std::vector<std::string> extract_links(const std::string& body) {
    std::vector<std::string> out;
    const std::string masked = mask_fences(body);
    for (auto it = std::sregex_iterator(masked.begin(), masked.end(), re_link());
         it != std::sregex_iterator(); ++it) {
        out.push_back((*it)[1].str());
    }
    return out;
}

std::vector<std::string> extract_wikilinks(const std::string& body) {
    std::vector<std::string> out;
    const std::string masked = mask_fences(body);
    for (auto it = std::sregex_iterator(masked.begin(), masked.end(), re_wikilink());
         it != std::sregex_iterator(); ++it) {
        std::string m = (*it)[1].str();
        out.push_back(trim(m.substr(0, m.find('|'))));
    }
    return out;
}

std::vector<std::pair<std::string, std::string>> fm_paths(const json& fm) {
    std::vector<std::pair<std::string, std::string>> out;
    if (!fm.is_object()) return out;
    auto push = [&out](const char* kind, const json& v) {
        if (v.is_string()) {
            std::string s = v.get<std::string>();
            if (!s.empty()) out.emplace_back(kind, s);
        }
    };
    auto at = [&fm](const char* k) -> json {
        auto it = fm.find(k);
        return it == fm.end() ? json(nullptr) : *it;
    };
    push("resource", at("resource"));
    push("computation", at("computation"));
    json ex = at("executor");
    if (ex.is_object()) push("executor", ex.contains("resource") ? ex["resource"] : json(nullptr));
    json at_ = at("attester");
    if (at_.is_object()) push("attester", at_.contains("resource") ? at_["resource"] : json(nullptr));
    json ss = at("sources");
    if (ss.is_array()) {
        for (const json& s : ss) {
            if (s.is_object() && s.contains("resource")) push("source", s["resource"]);
        }
    } else if (ss.is_object() && ss.contains("resource")) {
        push("source", ss["resource"]);
    }
    return out;
}

bool is_scope(const std::string& raw) {
    for (unsigned char ch : raw) {
        if (std::isspace(ch)) return true;
    }
    return false;
}

std::optional<std::pair<std::string, std::string>> resolve_path(
    const std::string& raw, const std::string& src_rel, const std::set<std::string>& targets) {
    std::string t = before_hash(raw);
    std::string spec;
    if (!t.empty() && t[0] == '/') {
        spec = norm(t.substr(1));
    } else {
        std::size_t slash = src_rel.rfind('/');
        spec = norm(slash == std::string::npos ? t : src_rel.substr(0, slash) + "/" + t);
    }
    if (targets.count(spec)) return std::make_pair(spec, std::string("spec"));
    std::string root = norm(!t.empty() && t[0] == '/' ? t.substr(1) : t);
    if (targets.count(root)) return std::make_pair(root, std::string("root"));
    return std::nullopt;
}

// The concept graph. Three edge sources, in this order: markdown links,
// wikilinks, and the path-valued frontmatter fields of SPEC 6.2. The last group
// carries the derivation and execution edges, which appear nowhere in the body.
std::vector<Link> links(const Bundle& b) {
    WikiIndex idx = wiki_index(b.concepts);
    const std::set<std::string>& targets = b.files.empty() ? b.known : b.files;
    std::vector<Link> out;
    for (const Concept& c : b.concepts) {
        for (const std::string& raw : c.links_raw) {
            if (is_external(raw)) continue;
            std::optional<std::string> dst = resolve_link(raw, c.path, b.known);
            std::string target = dst ? "concept"
                                     : (resolve_path(raw, c.path, targets) ? "file" : "missing");
            out.push_back(Link{c.path, raw, dst, dst.has_value(), "body", target});
        }
        for (const std::string& raw : c.wikilinks_raw) {
            std::optional<std::string> dst = resolve_wiki(raw, idx, b.known);
            out.push_back(Link{c.path, raw, dst, dst.has_value(), "wikilink",
                               dst ? "concept" : "missing"});
        }
    }
    // Frontmatter edges are appended last, so body-link ordering is untouched.
    for (const Concept& c : b.concepts) {
        for (const auto& fp : fm_paths(c.frontmatter)) {
            const std::string& kind = fp.first;
            const std::string& raw = fp.second;
            if (is_external(raw)) continue;
            if (kind == "source" && is_scope(raw)) {
                out.push_back(Link{c.path, raw, std::nullopt, false, kind, "scope"});
                continue;
            }
            auto r = resolve_path(raw, c.path, targets);
            if (!r) {
                out.push_back(Link{c.path, raw, std::nullopt, false, kind, "missing"});
                continue;
            }
            bool is_concept = b.known.count(r->first) > 0;
            out.push_back(Link{c.path, raw,
                               is_concept ? std::optional<std::string>(r->first) : std::nullopt,
                               is_concept, kind, is_concept ? "concept" : "file"});
        }
    }
    return out;
}
}  // namespace okf
