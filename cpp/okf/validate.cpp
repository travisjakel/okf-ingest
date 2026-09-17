// OKF validation rules — mirrors py/okf/okf.py::validate verbatim.
// Permissive consumption: recommended-field issues are warnings; only
// unparseable frontmatter / missing type are errors.

#include <regex>

#include "okf.hpp"

namespace okf {

std::vector<Finding> validate(const Bundle& b) {
    // SPEC 5: every timestamp-valued key is an ISO 8601 datetime with an
    // explicit UTC offset. Upstream made this literal on 2026-08-21 and the
    // reference bundles now emit "+00:00", so a trailing-Z-only pattern
    // rejected 44 of 44 conformant concepts. A bare local datetime still
    // fails: the offset is the point of the rule.
    static const std::regex re_iso(R"(^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$)");
    std::vector<Finding> out;
    auto add = [&out](const std::string& path, const char* sev, const char* rule,
                      const std::string& msg) {
        out.push_back(Finding{path, sev, rule, msg});
    };

    for (const Concept& c : b.concepts) {
        if (c.reserved) continue;
        if (c.parse_error) {
            add(c.path, "error", "frontmatter_unparseable",
                "no parseable frontmatter (" + *c.parse_error + ")");
            continue;
        }
        if (!c.type || c.type->empty()) {
            add(c.path, "error", "missing_type", "frontmatter has no non-empty type");
        }
        if (!c.title) add(c.path, "warn", "missing_title", "recommended field title absent");
        if (!c.description) {
            add(c.path, "warn", "missing_description", "recommended field description absent");
        }
        if (!c.timestamp) {
            add(c.path, "warn", "missing_timestamp", "recommended field timestamp absent");
        } else if (!std::regex_match(*c.timestamp, re_iso)) {
            add(c.path, "warn", "timestamp_not_iso8601",
                "timestamp not ISO-8601: " + *c.timestamp);
        }
    }

    std::vector<Link> lk_all = links(b);
    for (const Link& lk : lk_all) {
        if (lk.target == "concept" || lk.target == "scope") continue;
        if (lk.target == "file") {
            // The target exists, it is simply not a concept (an attester .py, a
            // computation .sql). SPEC 6.2 and 6.3 expect exactly this.
            add(lk.src_path, "info", "non_concept_target",
                "reference resolves to a non-concept file: " + lk.dst_raw);
        } else if (lk.kind == "body" || lk.kind == "wikilink") {
            add(lk.src_path, "warn", "broken_link", "unresolved link: " + lk.dst_raw);
        } else {
            add(lk.src_path, "warn", "broken_reference",
                "unresolved " + lk.kind + " path: " + lk.dst_raw);
        }
    }

    // A frontmatter path that resolves only against the bundle root, though
    // SPEC 6.2 reserves that meaning for a leading slash. Reported so a
    // producer can fix it; consumed regardless (permissive, SPEC 11).
    const std::set<std::string>& targets = b.files.empty() ? b.known : b.files;
    for (const Concept& c : b.concepts) {
        for (const auto& fp : fm_paths(c.frontmatter)) {
            const std::string& kind = fp.first;
            const std::string& raw = fp.second;
            if (!raw.empty() && raw[0] == '/') continue;
            if (kind == "source" && is_scope(raw)) continue;
            auto r = resolve_path(raw, c.path, targets);
            if (r && r->second == "root") {
                add(c.path, "info", "path_root_relative",
                    kind + " path resolves against the bundle root, not the concept " +
                        "directory; SPEC 6.2 reserves that for a leading slash: " + raw);
            }
        }
    }

    // orphan concepts: non-reserved, parseable, no inbound link
    std::set<std::string> inbound;
    for (const Link& lk : lk_all) {
        if (lk.dst_path) inbound.insert(*lk.dst_path);
    }
    for (const Concept& c : b.concepts) {
        if (c.reserved || c.parse_error) continue;
        if (!inbound.count(c.path)) {
            add(c.path, "warn", "orphan", "no inbound links (orphan concept)");
        }
    }
    return out;
}

}  // namespace okf
