## R CMD check results

0 errors | 0 warnings | 2 notes

* "New submission" — this is a new release.
* "unable to verify current time" — environmental (the check host had no network
  to reach the time server); not a package issue.

## Test environments

- Windows 11, R 4.5.0 (local)
- GitHub Actions: ubuntu-latest, macos-latest, windows-latest (R release)

## Notes

* The remaining NOTE is the standard "new submission" / incoming-feasibility note.
* The package optionally talks to a local Ollama server for embeddings
  (`okf_ollama_embedder`/`okf_embed`/`okf_rag`) and can fetch remote bundles
  (git/tar/zip) in `okf_fetch`; none of this runs during checks, examples, or
  tests — all tests use a small inline bundle in `tempdir()` and no network.
* `commonmark` (HTML rendering) and `httr2` (embeddings) are Suggests, guarded
  with `requireNamespace()`.
