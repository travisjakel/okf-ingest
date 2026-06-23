#!/usr/bin/env Rscript
# ============================================================================
# okf — command-line interface (R). Mirrors py/okf/cli.py.
#
#   okf validate <bundle> [--strict] [--json]
#   okf ingest   <bundle|git-url|tar/zip> --db <path> [--id <id>] [--subdir <p>] [--branch <b>] [--incremental] [--json]
#   okf query    <db> [--sql "SELECT ..."] [--search <term>]
#                     [--concepts] [--links] [--findings] [--json]
#   okf context  <bundle|db> [--start <path>] [--depth N] [--max-tokens N] [--no-index]
#   okf html     <bundle|db> --out <dir> | --single <file.html> [--title T]
#   okf graph    <bundle|db> --out <file.html> [--title T]
#   okf export   <bundle|db> [--json]                 # portable {nodes, edges} graph JSON
#   okf impact   <bundle|db> <concept>  [--json]      # inbound / outbound / transitive
#   okf embed    <db> [--model nomic-embed-text] [--incremental] [--json]
#   okf rag      <db> --query "..." [-k 5] [--model nomic-embed-text] [--json]
#
# Exit codes: 0 ok · 1 conformance failure (errors, or warnings under --strict)
#             · 2 usage error
# ============================================================================
suppressPackageStartupMessages({ library(jsonlite) })

self <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
if (requireNamespace("okf", quietly = TRUE)) {
  suppressPackageStartupMessages(library(okf))           # installed package
} else if (length(self) && nzchar(self)) {
  rdir <- file.path(normalizePath(file.path(dirname(self), ".."), mustWork = FALSE), "R")
  for (f in c("okf.R", "okf_html.R", "okf_graph.R")) source(file.path(rdir, f))  # dev fallback
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
                     include_index = !flag("--no-index"))
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
  cat(okf_graph_json(con, pretty = TRUE), "\n")
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
