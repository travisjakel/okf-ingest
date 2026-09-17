#!/usr/bin/env Rscript
# ============================================================================
# okf — command-line interface (R). Mirrors py/okf/cli.py.
#
#   okf validate <bundle> [--strict] [--json]
#   okf ingest   <bundle|git-url|tar/zip> --db <path> [--id <id>] [--subdir <p>] [--branch <b>] [--incremental] [--json]
#   okf query    <db> [--sql "SELECT ..."] [--search <term>]
#                     [--concepts] [--links] [--findings] [--json]
#   okf context  <bundle|db> [--start <path>] [--depth N] [--max-tokens N] [--no-index] [--rank ppr] [--query "..."]
#   okf html     <bundle|db> --out <dir> | --single <file.html> [--title T]
#   okf graph    <bundle|db> --out <file.html> [--title T]
#   okf export   <bundle|db> [--json] [--mermaid]     # portable {nodes, edges} graph JSON, or a Mermaid diagram
#   okf impact   <bundle|db> <concept>  [--json]      # inbound / outbound / transitive
#   okf doctor   <bundle|db> [--strict] [--stale-days N] [--fix] [--json]  # health / maintenance
#   okf diff     <a> <b> [--json]                     # concept-level changelog; each side a bundle dir or .duckdb
#   okf rank     <bundle|db> <concept> [-k N] [--json]  # Personalized PageRank relevance to a concept
#   okf embed    <db> [--model nomic-embed-text] [--incremental] [--json]
#   okf rag      <db> --query "..." [-k 5] [--model nomic-embed-text] [--json]
#
# Exit codes: 0 ok · 1 conformance failure (errors, or warnings under --strict)
#             · 2 usage error
# ============================================================================
suppressPackageStartupMessages({ library(jsonlite) })

self <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
okf_src_dir <- if (length(self) && nzchar(self))
  normalizePath(file.path(dirname(self), ".."), mustWork = FALSE) else NA_character_

# Version guard: this script lives INSIDE the package source tree, so an installed
# `okf` of a different version means the CLI would silently run code that is not
# the code sitting next to it. Refuse rather than prefer one arbitrarily; set
# OKF_ALLOW_VERSION_MISMATCH=1 to override.
.okf_src_version <- function(dir) {
  if (is.na(dir)) return(NA_character_)
  d <- file.path(dir, "DESCRIPTION")
  if (!file.exists(d)) return(NA_character_)
  v <- read.dcf(d, fields = "Version")[1, 1]
  if (is.na(v)) NA_character_ else as.character(v)
}

if (requireNamespace("okf", quietly = TRUE)) {
  inst <- as.character(utils::packageVersion("okf"))
  src  <- .okf_src_version(okf_src_dir)
  if (!is.na(src) && src != inst && !nzchar(Sys.getenv("OKF_ALLOW_VERSION_MISMATCH")))
    stop(sprintf(paste0(
      "okf version mismatch: installed package is %s but the source tree next to this
",
      "  script is %s (%s).
",
      "  Reinstall with:  R CMD INSTALL %s
",
      "  Or set OKF_ALLOW_VERSION_MISMATCH=1 to run the installed package anyway."),
      inst, src, okf_src_dir, shQuote(okf_src_dir)), call. = FALSE)
  suppressPackageStartupMessages(library(okf))           # installed package
} else if (!is.na(okf_src_dir)) {
  rdir <- file.path(okf_src_dir, "R")
  for (f in c("okf.R", "okf_html.R", "okf_graph.R", "okf_doctor.R", "okf_diff.R", "okf_rank.R")) source(file.path(rdir, f))  # dev fallback
} else stop("okf is not installed and the dev source could not be located")

args <- commandArgs(trailingOnly = TRUE)
flag  <- function(name) name %in% args
optval <- function(name, default = NULL) {
  i <- which(args == name)
  if (length(i) && i[1] < length(args)) return(args[i[1] + 1])
  kv <- grep(paste0("^", name, "="), args, value = TRUE)
  if (length(kv)) return(sub(paste0("^", name, "="), "", kv[1]))
  default
}
out_json <- flag("--json")
emit <- function(x) if (out_json) cat(jsonlite::toJSON(x, auto_unbox = TRUE, pretty = TRUE), "\n")

usage <- function(code = 2) {
  cat("usage:\n",
      "  okf validate <bundle> [--strict] [--json]\n",
      "  okf ingest   <bundle|git-url|tar/zip> --db <path> [--subdir <p>] [--branch <b>] [--json]\n",
      "  okf query    <db> [--sql \"...\"] [--search <term>] [--concepts] [--links] [--findings] [--json]\n",
      sep = "")
  quit(status = code)
}

cmd <- if (length(args)) args[1] else ""
pos <- args[2]

if (cmd == "validate") {
  if (is.na(pos)) usage()
  rd  <- okf_read(pos)
  val <- okf_validate(rd)
  nerr <- sum(val$severity == "error"); nwarn <- sum(val$severity == "warn")
  conf <- nerr == 0
  if (out_json) {
    emit(list(bundle = pos, conformant = conf, errors = nerr, warnings = nwarn,
              findings = if (nrow(val)) val else list()))
  } else {
    cat(sprintf("bundle: %s\nconformant: %s  (errors: %d, warnings: %d)\n",
                pos, conf, nerr, nwarn))
    if (nrow(val)) for (i in seq_len(nrow(val)))
      cat(sprintf("  [%-5s] %-22s %s — %s\n", val$severity[i], val$rule[i], val$path[i], val$message[i]))
  }
  quit(status = if (!conf || (flag("--strict") && nwarn > 0)) 1 else 0)

} else if (cmd == "ingest") {
  if (is.na(pos)) usage()
  db <- optval("--db", ":memory:")
  res <- okf_ingest(pos, db_path = db, bundle_id = optval("--id"),
                    subdir = optval("--subdir"), branch = optval("--branch"),
                    incremental = flag("--incremental"))
  DBI::dbDisconnect(res$con, shutdown = TRUE)
  if (out_json) emit(c(list(bundle = pos, db = db, bundle_id = res$bundle_id), res$summary))
  else {
    s <- res$summary
    cat(sprintf("ingested %s -> %s\n  bundle_id=%s\n  concepts=%d conformant=%d (%s) errors=%d warnings=%d links=%d broken=%d\n",
                pos, db, res$bundle_id, s$n_concepts, s$n_conformant, s$conformant,
                s$errors, s$warnings, s$links_total, s$links_broken))
    if (!is.null(s$changed)) cat(sprintf("  incremental: changed=%d added=%d removed=%d cached=%d\n",
                                         s$changed, s$added, s$removed, s$cached))
  }
  quit(status = if (res$summary$conformant) 0 else 1)

} else if (cmd == "query") {
  if (is.na(pos)) usage()
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  res <- if (!is.null(optval("--sql"))) DBI::dbGetQuery(con, optval("--sql"))
    else if (!is.null(optval("--search"))) okf_search(con, optval("--search"))
    else if (flag("--links")) okf_graph_df(con)
    else if (flag("--findings")) okf_findings(con)
    else okf_concepts(con)
  if (out_json) emit(res) else print(res, row.names = FALSE)
  quit(status = 0)

} else if (cmd == "context") {
  if (is.na(pos)) usage()
  if (grepl("\\.duckdb$", pos) && file.exists(pos)) {
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = TRUE)
  } else {
    res <- okf_ingest(pos, subdir = optval("--subdir"), branch = optval("--branch"))
    con <- res$con
  }
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ctx <- okf_context(con, start = optval("--start"),
                     depth = as.integer(optval("--depth", "1")),
                     max_tokens = as.integer(optval("--max-tokens", "8000")),
                     include_index = !flag("--no-index"),
                     rank = optval("--rank", "bfs"),
                     query = optval("--query"))
  cat(ctx$text)
  cat(sprintf("\n<!-- okf context: %d concepts, ~%d tokens, %d omitted -->\n",
              length(ctx$included), ctx$est_tokens, length(ctx$omitted)), file = stderr())
  quit(status = 0)

} else if (cmd == "html") {
  if (is.na(pos)) usage()
  single_out <- optval("--single")
  if (grepl("\\.duckdb$", pos) && file.exists(pos)) {
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = TRUE)
  } else {
    res <- okf_ingest(pos, subdir = optval("--subdir"), branch = optval("--branch"))
    con <- res$con
  }
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  single <- !is.null(single_out)
  out <- if (single) single_out else optval("--out")
  if (is.null(out)) { cat("html: need --out <dir> or --single <file.html>\n"); quit(status = 2) }
  r <- okf_html(con, out, single = single, site_title = optval("--title"))
  if (out_json) emit(list(mode = r$mode, n_concepts = r$n_concepts, files = r$files))
  quit(status = 0)

} else if (cmd == "graph") {
  if (is.na(pos)) usage()
  out <- optval("--out"); if (is.null(out)) { cat("graph: need --out <file.html>\n"); quit(status = 2) }
  if (grepl("\\.duckdb$", pos) && file.exists(pos)) {
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = TRUE)
  } else { res <- okf_ingest(pos, subdir = optval("--subdir"), branch = optval("--branch")); con <- res$con }
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  okf_graph_html(con, out, site_title = optval("--title"))
  quit(status = 0)

} else if (cmd == "export") {
  if (is.na(pos)) usage()
  if (grepl("\\.duckdb$", pos) && file.exists(pos)) {
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = TRUE)
  } else { res <- okf_ingest(pos, subdir = optval("--subdir"), branch = optval("--branch")); con <- res$con }
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  if (flag("--mermaid")) cat(okf_graph_mermaid(con), "\n") else cat(okf_graph_json(con, pretty = TRUE), "\n")
  quit(status = 0)

} else if (cmd == "impact") {
  if (is.na(pos) || is.na(args[3])) { cat("impact: usage: okf impact <bundle|db> <concept>\n"); quit(status = 2) }
  concept <- args[3]
  if (grepl("\\.duckdb$", pos) && file.exists(pos)) {
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = TRUE)
  } else { res <- okf_ingest(pos, subdir = optval("--subdir"), branch = optval("--branch")); con <- res$con }
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  im <- okf_impact(con, concept)
  if (out_json) emit(im)
  else cat(sprintf("impact of %s\n  outbound (%d): %s\n  inbound (%d): %s\n  transitive (%d): %s\n",
                   concept, length(im$outbound), paste(im$outbound, collapse = ", "),
                   length(im$inbound), paste(im$inbound, collapse = ", "),
                   length(im$transitive), paste(im$transitive, collapse = ", ")))
  quit(status = 0)

} else if (cmd == "doctor") {
  if (is.na(pos)) usage()
  is_db <- grepl("\\.duckdb$", pos) && file.exists(pos)
  if (flag("--fix")) {
    if (is_db) { cat("doctor --fix needs a bundle directory (not a .duckdb catalog)\n"); quit(status = 2) }
    fx <- okf_doctor_fix(pos)
    if (nrow(fx)) for (i in seq_len(nrow(fx)))
      cat(sprintf("  fixed [%s] %s: %s -> %s\n", fx$kind[i], fx$path[i], fx$before[i], fx$after[i]))
    else cat("  no safely-fixable issues\n")
  }
  if (is_db) con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = TRUE)
  else { res <- okf_ingest(pos, subdir = optval("--subdir"), branch = optval("--branch")); con <- res$con }
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  sd <- optval("--stale-days"); now <- if (!is.null(sd)) format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC") else NULL
  rep <- okf_doctor(con, now = now, stale_days = if (!is.null(sd)) as.integer(sd) else NULL)
  if (out_json) emit(rep)
  else {
    cat(sprintf("health: %d/100  (%d/%d concepts clean · %d errors · %d warnings)\n",
                rep$score, rep$n_healthy, rep$n_concepts, rep$n_error, rep$n_warn))
    if (length(rep$by_rule)) for (r in names(rep$by_rule))
      cat(sprintf("  %-22s %d\n", r, rep$by_rule[[r]]))
  }
  ok <- rep$n_error == 0 && !(flag("--strict") && rep$n_warn > 0)
  quit(status = if (ok) 0 else 1)

} else if (cmd == "rank") {
  if (is.na(pos) || is.na(args[3])) { cat("rank: usage: okf rank <bundle|db> <concept> [-k N]\n"); quit(status = 2) }
  if (grepl("\\.duckdb$", pos) && file.exists(pos)) {
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = TRUE)
  } else { res <- okf_ingest(pos, subdir = optval("--subdir"), branch = optval("--branch")); con <- res$con }
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  rk <- okf_rank(con, args[3], k = as.integer(optval("-k", "20")))
  if (out_json) emit(rk)
  else for (i in seq_len(nrow(rk)))
    cat(sprintf("%.10f %s%s\n", rk$score[i], rk$path[i], if (rk$reserved[i]) " (reserved)" else ""))
  quit(status = 0)

} else if (cmd == "diff") {
  if (is.na(pos) || is.na(args[3])) { cat("diff: usage: okf diff <a> <b>  (each side a bundle dir or .duckdb catalog)\n"); quit(status = 2) }
  d <- okf_diff(pos, args[3])
  if (out_json) emit(d)
  else {
    s <- d$summary
    cat(sprintf("diff %s -> %s\n", pos, args[3]))
    cat(sprintf("concepts: +%d added / -%d removed / ~%d changed (%d unchanged), type-changed %d, retitled %d\n",
                s$added, s$removed, s$changed, s$unchanged, s$type_changed, s$retitled))
    for (p in d$added)   cat(sprintf("  + %s\n", p))
    for (p in d$removed) cat(sprintf("  - %s\n", p))
    for (p in d$changed) cat(sprintf("  ~ %s\n", p))
    if (nrow(d$type_changed)) for (i in seq_len(nrow(d$type_changed)))
      cat(sprintf("  ~ %s  type: %s -> %s\n", d$type_changed$path[i], d$type_changed$from[i], d$type_changed$to[i]))
    if (nrow(d$retitled)) for (i in seq_len(nrow(d$retitled)))
      cat(sprintf("  ~ %s  title: %s -> %s\n", d$retitled$path[i], d$retitled$from[i], d$retitled$to[i]))
    cat(sprintf("links: +%d added / -%d removed, newly broken %d, fixed %d\n",
                s$links_added, s$links_removed, s$broken_added, s$broken_fixed))
    if (nrow(d$links_added)) for (i in seq_len(nrow(d$links_added)))
      cat(sprintf("  + %s -> %s\n", d$links_added$src_path[i], d$links_added$dst_path[i]))
    if (nrow(d$links_removed)) for (i in seq_len(nrow(d$links_removed)))
      cat(sprintf("  - %s -> %s\n", d$links_removed$src_path[i], d$links_removed$dst_path[i]))
    if (nrow(d$broken_added)) for (i in seq_len(nrow(d$broken_added)))
      cat(sprintf("  ! %s -> %s (now broken)\n", d$broken_added$src_path[i], d$broken_added$dst_raw[i]))
    if (nrow(d$broken_fixed)) for (i in seq_len(nrow(d$broken_fixed)))
      cat(sprintf("  = %s -> %s (no longer broken)\n", d$broken_fixed$src_path[i], d$broken_fixed$dst_raw[i]))
    if (d$identical) cat("identical: no differences\n")
  }
  quit(status = if (d$identical) 0 else 1)

} else if (cmd == "embed") {
  if (is.na(pos)) usage()
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  n <- okf_embed(con, embedder = okf_ollama_embedder(optval("--model", "nomic-embed-text")),
                 incremental = flag("--incremental"))
  if (out_json) emit(list(db = pos, chunks = n)) else cat(sprintf("embedded %d chunks into %s\n", n, pos))
  quit(status = 0)

} else if (cmd == "rag") {
  if (is.na(pos)) usage()
  q <- optval("--query"); if (is.null(q)) usage()
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = pos, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  res <- okf_rag(con, q, embedder = okf_ollama_embedder(optval("--model", "nomic-embed-text")),
                 k = as.integer(optval("-k", "5")))
  if (out_json) emit(res)
  else for (i in seq_len(nrow(res)))
    cat(sprintf("[%.3f] %s#%d — %s\n    %s\n", res$score[i], res$path[i], res$chunk_id[i],
                res$title[i], substr(gsub("\n", " ", res$text[i]), 1, 160)))
  quit(status = 0)

} else usage()
