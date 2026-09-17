---
type: Index
title: References
description: In-bundle stand-ins for source material that lives outside the bundle.
timestamp: 2026-09-17T00:00:00Z
generated: { by: hand, at: 2026-09-17T00:00:00Z }
status: stable
tags: [okf, references]
---

# References

SPEC 6.3. A `sources[].resource` that is a relative path must resolve *inside*
the bundle — pointing it at `../../r/okf` names something real and still reads
as a broken reference, because a consumer who fetched this bundle alone could
not follow it.

So each outside thing gets a concept here that says what it is and where it
lives, and citations point at the concept. The indirection is the honest part:
the bundle stays self-contained and the pointer stays truthful.

* [The R binding](r-binding.md)
* [The Python binding](py-binding.md)
* [The conformance corpus](conformance-corpus.md)
