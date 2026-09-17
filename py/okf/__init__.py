"""okf — Open Knowledge Format ingestion (Python binding)."""
from .okf import read_bundle, validate, links, ingest, search, fetch, context, Bundle, Concept
# Note: import the function as `rag_search` so it does not shadow the `okf.rag`
# submodule (i.e. `import okf.rag` keeps returning the module, not this fn).
from .rag import chunk_body, ollama_embedder, embed
from .rag import rag as rag_search
from .html import render_html
from .graph import backlinks, impact, clusters, graph_json, graph_html, graph_mermaid, ppr, seeds
from .doctor import doctor, doctor_fix
from .diff import diff, bundle_state
# OKF v0.2 semantics (SPEC 5 trust/lifecycle, SPEC 10 attested computations).
# Read-and-bind only: nothing here executes or attests anything.
from .trust import (trust, sources, computations, bind, canonicalize,
                    footnote_labels, instant)

__all__ = ["read_bundle", "validate", "links", "ingest", "search", "fetch", "context",
           "Bundle", "Concept", "chunk_body", "ollama_embedder", "embed", "rag_search",
           "render_html", "backlinks", "impact", "clusters", "graph_json", "graph_html",
           "graph_mermaid", "ppr", "seeds", "doctor", "doctor_fix", "diff", "bundle_state",
           "trust", "sources", "computations", "bind", "canonicalize",
           "footnote_labels", "instant"]
