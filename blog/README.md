# Blog drafts

Demo write-ups showing okf-ingest end-to-end by turning a real book into a
queryable knowledge graph. Two versions of the same story:

- [`post-r-bloggers.md`](post-r-bloggers.md) — R (for R-bloggers)
- [`post-python.md`](post-python.md) — Python

Every number and code block in the posts is from a **real run** against Christoph
Molnar's [*Interpretable Machine Learning*](https://github.com/christophM/interpretable-ml-book)
(CC BY-NC-SA): 47 Quarto chapters → a 49-concept OKF bundle (0 broken links,
`doctor` 100/100), embedded into 1369 chunks, with a Shapley-value RAG query and
the graph below — and the R and Python bindings produce the byte-identical
catalog.

![The book as a knowledge graph](iml-graph.png)

## Reproduce

The converted book bundle is **not** committed here — it's a derivative of an
NC-licensed book, and this repo is Apache-2.0. Regenerate it from a fresh clone:

```bash
git clone --depth 1 https://github.com/christophM/interpretable-ml-book src
Rscript convert.R      # or: python convert.py   (both produce the same iml-okf/ bundle)
okf ingest iml-okf --db iml.duckdb
okf doctor iml-okf
okf graph  iml-okf --out iml-graph.html
```

`convert.R` / `convert.py` are the ~30-line converters the posts walk through.

## Publishing notes

- The book is used for demonstration/commentary, not redistribution (readers
  clone it themselves). Attribution + license are stated in each post.
- Host `iml-graph.png` wherever your blog serves images and fix the relative path.
- The posts say `pip install okf-ingest` / R-universe (both live) and do not claim
  CRAN yet — update once the CRAN submission is accepted.
