# okf (Python binding)

Python binding of **okf-ingest** — a unified ingestion tool for
[Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog)
(OKF) bundles. Validate a bundle, load it into a portable DuckDB catalog, and
semantically search it.

```bash
pip install okf-ingest
okf validate ./bundle
okf ingest   ./bundle --db catalog.duckdb
okf embed    catalog.duckdb            # uses local Ollama nomic-embed-text by default
okf rag      catalog.duckdb --query "how is revenue computed?" -k 5
```

```python
import okf
con, summary = okf.ingest("./bundle", db_path="catalog.duckdb")
okf.embed(con)                         # pluggable embedder
okf.rag_search(con, "revenue", k=5)
```

The catalog format is shared with the R binding (`okf` on CRAN-style install),
so you can ingest/embed in one language and query from the other. See the
[project README](https://github.com/travisjakel/okf-ingest) and `docs/` for the
full spec-conformance notes and architecture.
