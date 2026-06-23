# Deterministic, offline tests over a tiny inline bundle (no network, no Ollama).

make_bundle <- function(bad = FALSE) {
  d <- tempfile("okfb_"); dir.create(file.path(d, "sub"), recursive = TRUE)
  writeLines(c("---", "type: Index", "title: Home", "---", "# Home",
               "- [A](a.md)", "- [B](sub/b.md)"), file.path(d, "index.md"))
  writeLines(c("---", "type: Note", "title: A",
               "timestamp: 2026-01-01T00:00:00Z", "description: first note", "---",
               "# A", "see [B](sub/b.md)"), file.path(d, "a.md"))
  b_fm <- if (bad) c("---", "title: B", "---") else
                   c("---", "type: Note", "title: B", "description: second", "---")
  writeLines(c(b_fm, "# B"), file.path(d, "sub", "b.md"))
  d
}

test_that("ingest builds a catalog with concepts, links and validation", {
  res <- okf_ingest(make_bundle())
  on.exit(DBI::dbDisconnect(res$con, shutdown = TRUE))
  expect_equal(res$summary$n_concepts, 2L)        # a.md + sub/b.md (index.md reserved)
  expect_true(res$summary$conformant)
  expect_true("a.md" %in% okf_concepts(res$con)$path)
  expect_gt(nrow(okf_graph_df(res$con)), 0L)
})

test_that("graph helpers are deterministic and consistent", {
  res <- okf_ingest(make_bundle()); con <- res$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_true("a.md" %in% okf_backlinks(con, "sub/b.md"))
  im <- okf_impact(con, "sub/b.md")
  expect_true("a.md" %in% im$inbound)
  expect_identical(okf_clusters(con), okf_clusters(con))   # reproducible
  expect_match(okf_graph_json(con), "nodes")
  expect_match(okf_graph_mermaid(con), "graph LR")
})

test_that("validate flags a missing type and doctor scores health", {
  res <- okf_ingest(make_bundle(bad = TRUE)); con <- res$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  f <- okf_findings(con)
  expect_true("missing_type" %in% f$rule)
  rep <- okf_doctor(con)
  expect_true(rep$score >= 0 && rep$score <= 100)
  expect_gt(rep$n_error, 0L)
})

test_that("html render produces files when commonmark is available", {
  skip_if_not_installed("commonmark")
  res <- okf_ingest(make_bundle()); con <- res$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- tempfile("okfsite_")
  okf_html(con, out)
  expect_true(file.exists(file.path(out, "index.html")))
  expect_true(file.exists(file.path(out, "sub", "b.html")))
  g <- tempfile(fileext = ".html"); okf_graph_html(con, g)
  expect_true(file.exists(g))
})
