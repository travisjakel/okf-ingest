#!/usr/bin/env Rscript
# ============================================================================
# OKF extensions prototype (see DESIGN.md).
#
# Demonstrates that six proposed features collapse into THREE extension points
# plus ONE resolver -- all deterministic, all additive, none requiring a model:
#   * resolver     : path -> id -> alias -> title -> stem  (wikilinks, ids, renames)
#   * edge model   : okf_link + nullable {rel, link_kind}  (typed links, hierarchy)
#   * manifest     : okf.yml                               (vocabulary, bundle meta)
#
# Reuses okf::okf_parse_file for frontmatter. Builds the enriched node/edge
# model in memory and prints a report; no catalog writes (this is a spike).
# ============================================================================
suppressPackageStartupMessages(library(okf))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
.chr <- function(x) if (is.null(x)) character(0) else as.character(x)
lc <- function(x) tolower(trimws(x))

# --- read concepts (reuse okf's frontmatter parser) -------------------------
read_bundle_ext <- function(root) {
  files <- list.files(root, pattern = "\\.md$", recursive = TRUE, full.names = TRUE)
  lapply(files, function(f) {
    rel <- sub(paste0("^", gsub("([.|()\\^${}*+?\\[\\]\\\\])", "\\\\\\1", normalizePath(root, winslash="/")), "/?"),
               "", normalizePath(f, winslash = "/"))
    p <- okf_parse_file(f); m <- p$meta %||% list()
    list(path = rel, body = p$body %||% "", meta = m,
         id = .chr(m$id), type = .chr(m$type), title = .chr(m$title),
         aliases = .chr(m$aliases), parent = .chr(m$parent),
         relations = m$relations, timestamp = .chr(m$timestamp))
  })
}

# --- EXTENSION POINT 1: the layered resolver --------------------------------
# One index, fixed precedence. New reference kinds = new entries here, not new
# code paths. Returns the bundle-relative path or NA. Records key collisions.
build_resolver <- function(concepts) {
  known <- vapply(concepts, function(c) c$path, "")
  stem  <- function(p) sub("\\.md$", "", basename(p))
  maps <- list(id = list(), alias = list(), title = list(), stem = list())
  collide <- character(0)
  put <- function(map, key, path) {
    key <- lc(key); if (!nzchar(key)) return(map)
    if (!is.null(map[[key]]) && map[[key]] != path) collide <<- c(collide, key)
    map[[key]] <- path; map
  }
  for (c in concepts) {
    if (length(c$id))    maps$id    <- put(maps$id,    c$id,    c$path)
    if (length(c$title)) maps$title <- put(maps$title, c$title, c$path)
    for (a in c$aliases) maps$alias <- put(maps$alias, a, c$path)
    maps$stem <- put(maps$stem, stem(c$path), c$path)
  }
  list(
    collisions = unique(collide),
    resolve = function(ref, from = "") {
      ref <- sub("#.*$", "", trimws(ref)); if (!nzchar(ref)) return(NA_character_)
      # 1) explicit path (relative to the linking file or bundle root)
      cand <- c(ref, if (nzchar(from) && dirname(from) != ".") file.path(dirname(from), ref))
      cand <- sub("^\\./", "", cand)
      hit <- cand[cand %in% known]; if (length(hit)) return(hit[1])
      # 2..5) id -> alias -> title -> stem (case-insensitive)
      for (m in list(maps$id, maps$alias, maps$title, maps$stem)) {
        v <- m[[lc(ref)]]; if (!is.null(v)) return(v)
      }
      NA_character_
    })
}

# --- link extraction: markdown (with optional rel title) + wikilinks --------
extract_edges_raw <- function(c) {
  rows <- list(); add <- function(ref, rel, kind)
    rows[[length(rows)+1]] <<- list(src = c$path, ref = ref, rel = rel, kind = kind)
  # markdown links  [text](target "optional title")  -- title may carry rel:
  md <- regmatches(c$body, gregexpr('\\]\\(\\s*([^)\\s"]+)(?:\\s+"([^"]*)")?\\s*\\)', c$body, perl = TRUE))[[1]]
  for (lk in md) {
    tgt <- sub('\\]\\(\\s*([^)\\s"]+).*', '\\1', lk, perl = TRUE)
    ttl <- if (grepl('"', lk)) sub('.*"([^"]*)".*', '\\1', lk) else ""
    if (grepl("^[a-zA-Z][a-zA-Z0-9+.-]*:", tgt)) next            # external scheme
    rel <- if (grepl("^rel:", trimws(ttl))) trimws(sub("^rel:\\s*", "", ttl)) else NA_character_
    add(tgt, rel, "markdown")
  }
  # wikilinks  [[target|display]]
  wk <- regmatches(c$body, gregexpr("\\[\\[([^]]+)\\]\\]", c$body, perl = TRUE))[[1]]
  for (lk in wk) { inner <- sub("^\\[\\[(.*)\\]\\]$", "\\1", lk)
    add(strsplit(inner, "|", fixed = TRUE)[[1]][1], NA_character_, "wikilink") }
  # frontmatter relations:  rel -> [targets]
  if (length(c$relations)) for (rel in names(c$relations))
    for (tgt in .chr(c$relations[[rel]])) add(tgt, rel, "relation")
  # parent: -> a rel="parent" edge (hierarchy IS a typed link, not a subsystem)
  for (p in c$parent) add(p, "parent", "relation")
  rows
}

# --- assemble the enriched node + edge model --------------------------------
build_model <- function(root) {
  concepts <- read_bundle_ext(root)
  R <- build_resolver(concepts)
  edges <- list()
  for (c in concepts) for (e in extract_edges_raw(c)) {
    dst <- R$resolve(e$ref, e$src)
    edges[[length(edges)+1]] <- data.frame(src = e$src, ref = e$ref,
      dst = dst %||% NA_character_, rel = e$rel %||% NA_character_,
      link_kind = e$kind, resolved = !is.na(dst), stringsAsFactors = FALSE)
  }
  list(concepts = concepts, edges = if (length(edges)) do.call(rbind, edges) else
       data.frame(), collisions = R$collisions)
}

# --- EXTENSION POINT 3: manifest + opt-in vocabulary validation -------------
read_manifest <- function(root) {
  f <- file.path(root, "okf.yml"); if (!file.exists(f)) return(NULL)
  yaml::yaml.load(paste(readLines(f, warn = FALSE), collapse = "\n"))
}
validate_vocab <- function(model, manifest) {
  if (is.null(manifest)) return(character(0))
  w <- character(0)
  allowed_types <- names(manifest$types %||% list())
  allowed_rels  <- .chr(manifest$relations)
  reserved <- c("index.md", "log.md")
  for (c in model$concepts) {
    if (c$path %in% reserved) next
    if (length(allowed_types) && length(c$type) && !(c$type %in% allowed_types))
      w <- c(w, sprintf("[type] %s: '%s' not in manifest vocabulary", c$path, c$type))
    req <- manifest$types[[c$type]]$requires
    for (field in .chr(req)) if (!length(c[[field]]) || !nzchar(c[[field]]))
      w <- c(w, sprintf("[schema] %s: type '%s' requires '%s'", c$path, c$type, field))
  }
  if (nrow(model$edges) && length(allowed_rels)) {
    bad <- subset(model$edges, !is.na(rel) & !(rel %in% allowed_rels))
    for (i in seq_len(nrow(bad)))
      w <- c(w, sprintf("[rel] %s -> %s: relation '%s' not in vocabulary",
                        bad$src[i], bad$ref[i], bad$rel[i]))
  }
  w
}

# --- report -----------------------------------------------------------------
if (sys.nframe() == 0L) {
  root <- commandArgs(trailingOnly = TRUE)[1] %||% "prototype/demo"
  m <- build_model(root); man <- read_manifest(root)
  cat(sprintf("bundle: %s   (%d concepts)\n", root, length(m$concepts)))
  if (!is.null(man)) cat(sprintf("manifest: %s v%s  (okf %s, %s)\n",
      man$name, man$version, man$okf_version, man$license))
  cat("\n== enriched edges (extension point 1+2) ==\n")
  e <- m$edges
  e$rel[is.na(e$rel)] <- "-"
  print(e[order(e$src), c("src","ref","dst","rel","link_kind","resolved")], row.names = FALSE)
  cat("\n== hierarchy (just rel='parent' edges -- a view, not a subsystem) ==\n")
  par <- subset(m$edges, rel == "parent" & resolved)
  if (nrow(par)) for (i in seq_len(nrow(par))) cat(sprintf("  %s  ->  parent %s\n", par$src[i], par$dst[i]))
  cat("\n== resolution sources used ==\n")
  rk <- subset(m$edges, resolved & link_kind == "wikilink")
  cat(sprintf("  wikilinks resolved: %d / %d\n", sum(rk$resolved), nrow(subset(m$edges, link_kind=="wikilink"))))
  cat("\n== warnings (opt-in, never errors) ==\n")
  unl <- subset(m$edges, !resolved)
  for (i in seq_len(nrow(unl))) cat(sprintf("  [link] %s: unresolved reference '%s' (%s)\n",
                                            unl$src[i], unl$ref[i], unl$link_kind[i]))
  for (w in validate_vocab(m, man)) cat("  ", w, "\n", sep = "")
  if (length(m$collisions)) cat("  [resolve] ambiguous keys:", paste(m$collisions, collapse=", "), "\n")
}
