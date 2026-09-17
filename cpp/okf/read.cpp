// Bundle reading — mirrors py/okf/okf.py::read_bundle.
//
// Parity rules: hidden directories skipped; only *.md files not starting with
// '.'; concepts sorted by bundle-relative forward-slash path in byte order.

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "okf.hpp"

namespace fs = std::filesystem;

namespace okf {
namespace {

std::string slashify(const fs::path& p) {
    std::string s = p.generic_string();  // forward slashes
    // Strip the Windows extended-length prefix if canonicalization added it.
    if (s.rfind("//?/", 0) == 0) s = s.substr(4);
    return s;
}

void walk_md(const fs::path& dir, std::vector<fs::path>& out, std::vector<fs::path>& all) {
    for (const fs::directory_entry& entry : fs::directory_iterator(dir)) {
        std::string name = entry.path().filename().string();
        if (entry.is_directory()) {
            if (!name.empty() && name[0] != '.') walk_md(entry.path(), out, all);
        } else if (!name.empty() && name[0] != '.') {
            all.push_back(entry.path());
            if (name.size() > 3 && name.compare(name.size() - 3, 3, ".md") == 0) {
                out.push_back(entry.path());
            }
        }
    }
}

std::optional<std::string> scalar(const json& fm, const char* key) {
    if (!fm.is_object()) return std::nullopt;
    auto it = fm.find(key);
    if (it == fm.end() || it->is_null() || it->is_array() || it->is_object()) {
        return std::nullopt;
    }
    if (it->is_string()) return it->get<std::string>();
    return it->dump();
}

}  // namespace

Bundle read_bundle(const std::string& root, const std::string& source_kind) {
    fs::path root_path = fs::canonical(fs::path(root));
    std::string root_str = slashify(root_path);
    std::vector<fs::path> files, all_paths;
    walk_md(root_path, files, all_paths);

    Bundle b;
    for (const fs::path& f : all_paths) {
        b.files.insert(slashify(fs::relative(f, root_path)));
    }
    b.root = root_str;
    b.source_kind = source_kind;
    b.concepts.reserve(files.size());
    for (const fs::path& f : files) {
        std::string rel = slashify(fs::relative(f, root_path));
        std::ifstream in(f, std::ios::binary);
        if (!in) throw OkfError("cannot read " + f.string());
        std::ostringstream ss;
        ss << in.rdbuf();
        Parsed p = parse_text(ss.str());

        Concept c;
        c.path = rel;
        std::size_t slash = rel.rfind('/');
        std::string base = slash == std::string::npos ? rel : rel.substr(slash + 1);
        c.reserved = RESERVED.count(base) > 0;
        c.type = scalar(p.meta, "type");
        c.title = scalar(p.meta, "title");
        c.description = scalar(p.meta, "description");
        c.resource = scalar(p.meta, "resource");
        c.tags = p.meta.is_object() && p.meta.contains("tags") ? p.meta["tags"] : json(nullptr);
        c.timestamp = scalar(p.meta, "timestamp");
        // OKF v0.2: fall back to `generated: {by, at}` when the legacy
        // `timestamp` is absent (spec section 13).
        if (!c.timestamp && p.meta.is_object() && p.meta.contains("generated")) {
            c.timestamp = scalar(p.meta["generated"], "at");
        }
        c.frontmatter = p.meta;
        c.parse_error = p.parse_error;
        c.links_raw = extract_links(p.body);
        c.wikilinks_raw = extract_wikilinks(p.body);
        c.content_hash = content_hash(p.body);
        c.body = std::move(p.body);
        b.concepts.push_back(std::move(c));
    }
    std::sort(b.concepts.begin(), b.concepts.end(),
              [](const Concept& a, const Concept& c2) { return a.path < c2.path; });
    for (const Concept& c : b.concepts) b.known.insert(c.path);
    for (const Concept& c : b.concepts) {
        if (c.path == "index.md") {
            b.okf_version = scalar(c.frontmatter, "okf_version");
            break;
        }
    }
    b.bundle_id = content_hash(root_str);
    return b;
}

}  // namespace okf
