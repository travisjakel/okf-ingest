"""okf — Open Knowledge Format ingestion (Python binding)."""
from .okf import read_bundle, validate, links, ingest, search, fetch, Bundle, Concept
# Note: import the function as `rag_search` so it does not shadow the `okf.rag`
# submodule (i.e. `import okf.rag` keeps returning the module, not this fn).
from .rag import chunk_body, ollama_embedder, embed
from .rag import rag as rag_search

__all__ = ["read_bundle", "validate", "links", "ingest", "search", "fetch", "Bundle", "Concept",
           "chunk_body", "ollama_embedder", "embed", "rag_search"]
