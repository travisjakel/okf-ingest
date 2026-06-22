#!/usr/bin/env Rscript
# Conformance check: R binding vs conformance/expected/*.json.
# Run: Rscript conformance/check_r.R   (exit 0 = pass)
suppressPackageStartupMessages(library(jsonlite))
here <- tryCatch(dirname(sub("^--file=", "",
  grep("^--file=", commandArgs(FALSE), value = TRUE))), error = function(e) ".")
if (!length(here) || !nzchar(here)) here <- "conformance"
source(file.path(here, "..", "r", "okf", "R", "okf.R"))

fails <- character(0)
chk <- function(name, got, want)
  if (!identical(got, want)) fails <<- c(fails, sprintf("%s: got %s want %s", name,
    format(got), format(want)))

# store (conformant)
r  <- okf_ingest(file.path(here, "bundles", "store"))
ex <- jsonlite::fromJSON(file.path(here, "expected", "store.json"))$bundle
ver <- DBI::dbGetQuery(r$con, "SELECT okf_version FROM okf_bundle")$okf_version
chk("store.okf_version", ver, ex$okf_version)
chk("store.n_concepts",  r$summary$n_concepts,  ex$n_concepts)
chk("store.n_conformant",r$summary$n_conformant,ex$n_conformant)
chk("store.conformant",  r$summary$conformant,  ex$conformant)
chk("store.errors",      r$summary$errors,      0L)
chk("store.links_total", r$summary$links_total, 8L)
chk("store.links_broken",r$summary$links_broken,1L)
DBI::dbDisconnect(r$con, shutdown = TRUE)

# negative
r2  <- okf_ingest(file.path(here, "bundles", "negative"))
exn <- jsonlite::fromJSON(file.path(here, "expected", "negative.json"))
chk("negative.conformant", r2$summary$conformant, exn$bundle$conformant)
chk("negative.errors",     r2$summary$errors,      exn$validation$errors)
rules <- DBI::dbGetQuery(r2$con, "SELECT path, rule FROM okf_validation WHERE severity='error'")
for (i in seq_len(nrow(exn$validation$error_rules))) {
  er <- exn$validation$error_rules[i, ]
  chk(paste0("negative.", er$path), rules$rule[rules$path == er$path], er$rule)
}
DBI::dbDisconnect(r2$con, shutdown = TRUE)

if (length(fails)) { cat("FAIL\n  ", paste(fails, collapse = "\n  "), "\n"); quit(status = 1) }
cat("PASS — R binding conformant on all fixtures\n")
