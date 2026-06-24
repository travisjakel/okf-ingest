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
# cross-language content-hash parity lock
exh <- jsonlite::fromJSON(file.path(here, "expected", "store.json"))$content_hashes
goth <- DBI::dbGetQuery(r$con, "SELECT content_hash FROM okf_concept WHERE path='customers.md'")$content_hash
chk("store.content_hash[customers.md]", goth, exh$`customers.md`)
DBI::dbDisconnect(r$con, shutdown = TRUE)

# fetch path: ingest the same bundle from a tar archive (offline).
# Build the archive with "store/" at its root by taring from inside bundles/.
tmpd <- tempfile("okfa"); dir.create(tmpd)
tarp <- normalizePath(file.path(tmpd, "store.tar.gz"), winslash = "/", mustWork = FALSE)
.old <- getwd(); setwd(file.path(here, "bundles"))
utils::tar(tarp, files = "store", compression = "gzip")
setwd(.old)
r3 <- tryCatch(okf_ingest(tarp), error = function(e) {
  cat("fetch.tar ERROR:", conditionMessage(e), "\n")
  list(summary = list(n_concepts = -1L, conformant = NA)) })
chk("fetch.tar.n_concepts", r3$summary$n_concepts, 3L)
chk("fetch.tar.conformant", r3$summary$conformant, TRUE)
if (!is.null(r3$con)) DBI::dbDisconnect(r3$con, shutdown = TRUE)

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

# wikilinks ([[name]] resolved by id/alias/title/stem; markdown links unchanged)
rw  <- okf_ingest(file.path(here, "bundles", "wikilinks"))
exw <- jsonlite::fromJSON(file.path(here, "expected", "wikilinks.json"))
chk("wikilinks.n_concepts",   rw$summary$n_concepts,   exw$bundle$n_concepts)
chk("wikilinks.conformant",   rw$summary$conformant,   exw$bundle$conformant)
chk("wikilinks.links_total",  rw$summary$links_total,  exw$links$total)
chk("wikilinks.links_broken", rw$summary$links_broken, exw$links$broken)
wl <- DBI::dbGetQuery(rw$con, "SELECT src_path, dst_raw, dst_path FROM okf_link")
for (key in names(exw$resolutions)) {
  pp   <- strsplit(key, "|", fixed = TRUE)[[1]]
  got  <- wl$dst_path[wl$src_path == pp[1] & wl$dst_raw == pp[2]]
  want <- exw$resolutions[[key]]
  want <- if (is.null(want) || is.na(want)) NA_character_ else want
  chk(paste0("wikilinks.", key), got, want)
}
DBI::dbDisconnect(rw$con, shutdown = TRUE)

if (length(fails)) { cat("FAIL\n  ", paste(fails, collapse = "\n  "), "\n"); quit(status = 1) }
cat("PASS — R binding conformant on all fixtures\n")
