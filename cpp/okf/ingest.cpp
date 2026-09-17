// Ingest — mirrors py/okf/okf.py::ingest/_ingest_bundle, catalog-free (the
// conformance contract asserts only in-memory-derivable values).

#include <filesystem>

#include "okf.hpp"

namespace okf {

Ingested ingest_bundle(Bundle b) {
    Ingested ing;
    ing.findings = validate(b);
    ing.links = links(b);

    std::set<std::string> err_paths;
    for (const Finding& f : ing.findings) {
        if (f.severity == "error") err_paths.insert(f.path);
    }
    std::size_t n_non_reserved = 0, n_conf = 0;
    for (const Concept& c : b.concepts) {
        if (c.reserved) continue;
        ++n_non_reserved;
        if (!err_paths.count(c.path)) ++n_conf;
    }
    Summary& s = ing.summary;
    s.n_files = b.concepts.size();
    s.n_concepts = n_non_reserved;
    s.n_conformant = n_conf;
    s.conformant = err_paths.empty();
    for (const Finding& f : ing.findings) {
        // "info" is neither: it is a note for a producer, never a defect count.
        if (f.severity == "error") ++s.errors;
        else if (f.severity == "warn") ++s.warnings;
    }
    s.links_total = ing.links.size();
    for (const Link& l : ing.links) {
        if (l.target == "missing") ++s.links_broken;
    }
    ing.bundle = std::move(b);
    return ing;
}

Ingested ingest(const std::string& source) {
    if (std::filesystem::is_directory(source)) {
        return ingest_bundle(read_bundle(source, "dir"));
    }
    Fetched f = fetch(source);
    return ingest_bundle(read_bundle(f.dir, f.kind));
}

}  // namespace okf
