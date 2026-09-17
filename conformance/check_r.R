#!/usr/bin/env Rscript
# Conformance check: R binding vs conformance/expected/*.json.
# Run: Rscript conformance/check_r.R   (exit 0 = pass)
suppressPackageStartupMessages(library(jsonlite))
here <- tryCatch(dirname(sub("^--file=", "",
  grep("^--file=", commandArgs(FALSE), value = TRUE))), error = function(e) ".")
if (!length(here) || !nzchar(here)) here <- "conformance"
source(file.path(here, "..", "r", "okf", "R", "okf.R"))
source(file.path(here, "..", "r", "okf", "R", "okf_diff.R"))

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

# rank (Personalized PageRank: exact, deterministic, parity-locked)
source(file.path(here, "..", "r", "okf", "R", "okf_rank.R"))
rr  <- okf_ingest(file.path(here, "bundles", "store"))
exr <- jsonlite::fromJSON(file.path(here, "expected", "rank.json"))
gotr <- okf_rank(rr$con, exr$start, damping = exr$damping, k = 10)
chk("rank.paths",  gotr$path,                exr$ranking$path)
chk("rank.scores", round(gotr$score, 8),     exr$ranking$score)
DBI::dbDisconnect(rr$con, shutdown = TRUE)

# query seeding (lexical seeds -> multi-seed PPR, parity-locked)
rq  <- okf_ingest(file.path(here, "bundles", "store"))
exq <- jsonlite::fromJSON(file.path(here, "expected", "query.json"))
gots <- okf_seeds(rq$con, exq$query)
chk("query.seed_paths",  gots$path,  exq$seeds$path)
chk("query.seed_scores", gots$score, exq$seeds$score)
gotq <- okf_rank(rq$con, gots$path, weights = gots$score, k = 10)
chk("query.rank_paths",  gotq$path,            exq$ranking$path)
chk("query.rank_scores", round(gotq$score, 8), exq$ranking$score)
DBI::dbDisconnect(rq$con, shutdown = TRUE)

# diff (deterministic concept-level changelog between two bundle states)
dd  <- okf_diff(file.path(here, "bundles", "diff_a"), file.path(here, "bundles", "diff_b"))
exd <- jsonlite::fromJSON(file.path(here, "expected", "diff.json"))
as_chr <- function(x) if (length(x)) as.character(unlist(x)) else character(0)
key3 <- function(df) if (nrow(df)) paste(df[[1]], df[[2]], df[[3]], sep = "|") else character(0)
key2 <- function(df) if (nrow(df)) paste(df[[1]], df[[2]], sep = "|") else character(0)
chk("diff.identical",     dd$identical,          exd$identical)
chk("diff.added",         dd$added,              as_chr(exd$added))
chk("diff.removed",       dd$removed,            as_chr(exd$removed))
chk("diff.changed",       dd$changed,            as_chr(exd$changed))
chk("diff.type_changed",  key3(dd$type_changed), as_chr(exd$type_changed))
chk("diff.retitled",      key3(dd$retitled),     as_chr(exd$retitled))
chk("diff.links_added",   key2(dd$links_added),  as_chr(exd$links_added))
chk("diff.links_removed", key2(dd$links_removed),as_chr(exd$links_removed))
chk("diff.broken_added",  key2(dd$broken_added), as_chr(exd$broken_added))
chk("diff.broken_fixed",  key2(dd$broken_fixed), as_chr(exd$broken_fixed))
# drift mode: a catalog diffed against its own source directory is identical
rdup <- okf_ingest(file.path(here, "bundles", "diff_a"))
d0 <- okf_diff(rdup$con, file.path(here, "bundles", "diff_a"))
chk("diff.drift_identical", d0$identical, TRUE)
DBI::dbDisconnect(rdup$con, shutdown = TRUE)

# v0.2 (generated/sources/verified families; generated.at timestamp fallback)
rv  <- okf_ingest(file.path(here, "bundles", "v02"))
exv <- jsonlite::fromJSON(file.path(here, "expected", "v02.json"))
verv <- DBI::dbGetQuery(rv$con, "SELECT okf_version FROM okf_bundle")$okf_version
chk("v02.okf_version",  verv,                    exv$bundle$okf_version)
chk("v02.n_concepts",   rv$summary$n_concepts,   exv$bundle$n_concepts)
chk("v02.n_conformant", rv$summary$n_conformant, exv$bundle$n_conformant)
chk("v02.conformant",   rv$summary$conformant,   exv$bundle$conformant)
chk("v02.errors",       rv$summary$errors,       exv$validation$errors)
chk("v02.warnings",     rv$summary$warnings,     exv$validation$warnings)
chk("v02.links_total",  rv$summary$links_total,  exv$links$total)
chk("v02.links_broken", rv$summary$links_broken, exv$links$broken)
rules_v <- DBI::dbGetQuery(rv$con, "SELECT DISTINCT rule FROM okf_validation")$rule
for (fr in exv$validation$forbidden_rules)
  chk(paste0("v02.no_", fr), fr %in% rules_v, FALSE)
tsv <- DBI::dbGetQuery(rv$con, "SELECT path, timestamp FROM okf_concept")
for (pth in names(exv$timestamps)) {
  if (startsWith(pth, "_")) next
  chk(paste0("v02.timestamp[", pth, "]"), tsv$timestamp[tsv$path == pth],
      exv$timestamps[[pth]])
}
DBI::dbDisconnect(rv$con, shutdown = TRUE)

# v0.2 Attested Computation: SPEC 6.2 path-valued frontmatter fields as graph
# edges, non-concept targets, scope descriptors, both computation forms.
ra  <- okf_ingest(file.path(here, "bundles", "v02_attested"))
exa <- jsonlite::fromJSON(file.path(here, "expected", "v02_attested.json"))
chk("v02a.n_files",      ra$summary$n_files,      exa$bundle$n_files)
chk("v02a.n_concepts",   ra$summary$n_concepts,   exa$bundle$n_concepts)
chk("v02a.n_conformant", ra$summary$n_conformant, exa$bundle$n_conformant)
chk("v02a.conformant",   ra$summary$conformant,   exa$bundle$conformant)
chk("v02a.errors",       ra$summary$errors,       exa$validation$errors)
chk("v02a.warnings",     ra$summary$warnings,     exa$validation$warnings)
chk("v02a.links_total",  ra$summary$links_total,  exa$links$total)
chk("v02a.links_broken", ra$summary$links_broken, exa$links$broken)
rules_a <- DBI::dbGetQuery(ra$con, "SELECT DISTINCT rule FROM okf_validation")$rule
for (fr in exa$validation$forbidden_rules)
  chk(paste0("v02a.no_", fr), fr %in% rules_a, FALSE)
rc <- DBI::dbGetQuery(ra$con, "SELECT rule, COUNT(*) n FROM okf_validation GROUP BY rule")
for (rl in names(exa$validation$rule_counts))
  chk(paste0("v02a.rule[", rl, "]"), as.integer(sum(rc$n[rc$rule == rl])),
      as.integer(exa$validation$rule_counts[[rl]]))
bk <- DBI::dbGetQuery(ra$con, "SELECT kind, COUNT(*) n FROM okf_link GROUP BY kind")
for (kd in names(exa$links$by_kind))
  chk(paste0("v02a.kind[", kd, "]"), as.integer(sum(bk$n[bk$kind == kd])),
      as.integer(exa$links$by_kind[[kd]]))
bt <- DBI::dbGetQuery(ra$con, "SELECT target, COUNT(*) n FROM okf_link GROUP BY target")
for (tg in names(exa$links$by_target))
  chk(paste0("v02a.target[", tg, "]"), as.integer(sum(bt$n[bt$target == tg])),
      as.integer(exa$links$by_target[[tg]]))
la <- DBI::dbGetQuery(ra$con, "SELECT src_path, dst_raw, dst_path FROM okf_link")
for (key in names(exa$resolutions)) {
  if (startsWith(key, "_")) next
  pp <- strsplit(key, "|", fixed = TRUE)[[1]]
  chk(paste0("v02a.", key), la$dst_path[la$src_path == pp[1] & la$dst_raw == pp[2]],
      exa$resolutions[[key]])
}
tsa <- DBI::dbGetQuery(ra$con, "SELECT path, timestamp FROM okf_concept")
for (pth in names(exa$timestamps)) {
  if (startsWith(pth, "_")) next
  chk(paste0("v02a.timestamp[", pth, "]"), tsa$timestamp[tsa$path == pth],
      exa$timestamps[[pth]])
}
DBI::dbDisconnect(ra$con, shutdown = TRUE)

if (length(fails)) { cat("FAIL\n  ", paste(fails, collapse = "\n  "), "\n"); quit(status = 1) }
cat("PASS — R binding conformant on all fixtures\n")
