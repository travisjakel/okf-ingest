# ============================================================================
# okf -- Open Knowledge Format ingestion (R reference binding)
#
# Reads an OKF v0.1 bundle (a directory of markdown files with YAML
# frontmatter), validates conformance permissively, builds the concept graph,
# and loads everything into a portable DuckDB catalog (schema/catalog.sql).
#
# Public API:
#   okf_read(root)             -> in-memory bundle (concepts + raw links)
#   okf_validate(rd)           -> data.frame of conformance findings
#   okf_links(rd)              -> data.frame of resolved/broken graph edges
#   okf_ingest(root, db_path)  -> writes the DuckDB catalog; returns {con, summary}
#   okf_concepts/okf_graph_df/okf_search(con, ...) -> query helpers
# ============================================================================

# Dependencies are declared in DESCRIPTION (Imports) and accessed via `::`
# throughout, so this file is both a clean package source and directly
# `source()`-able for development. (Requires yaml, DBI, duckdb, digest,
# jsonlite installed; httr2 only for the default Ollama embedder.)

OKF_RESERVED <- c("index.md", "log.md")
`%||%` <- function(a, b) if (is.null(a)) b else a
.s <- function(x) if (is.null(x) || length(x) == 0) NA_character_ else as.character(x)[1]

# Mirror of schema/catalog.sql (kept in sync; that file is canonical).
OKF_SCHEMA <- "
CREATE TABLE IF NOT EXISTS okf_bundle (bundle_id TEXT PRIMARY KEY, root TEXT,
  okf_version TEXT, source_kind TEXT, ingested_at TEXT, n_concepts INTEGER,
  n_conformant INTEGER, conformant BOOLEAN);
CREATE TABLE IF NOT EXISTS okf_concept (bundle_id TEXT, path TEXT, reserved BOOLEAN,
  type TEXT, title TEXT, description TEXT, resource TEXT, tags TEXT, timestamp TEXT,
  body TEXT, frontmatter TEXT, parse_error TEXT, content_hash TEXT,
  PRIMARY KEY (bundle_id, path));
CREATE TABLE IF NOT EXISTS okf_link (bundle_id TEXT, src_path TEXT, dst_raw TEXT,
  dst_path TEXT, resolved BOOLEAN);
CREATE TABLE IF NOT EXISTS okf_validation (bundle_id TEXT, path TEXT, severity TEXT,
  rule TEXT, message TEXT);
CREATE TABLE IF NOT EXISTS okf_chunk (bundle_id TEXT, path TEXT, chunk_id INTEGER,
  text TEXT, embedding FLOAT[], content_hash TEXT);
"

#' Parse the YAML frontmatter and body of a single OKF concept file.
#'
#' @param path Path to a markdown file.
#' @return A list with `meta` (parsed frontmatter, or `NULL`), `body`, and
#'   `err` (`NA` on success, else `"no_frontmatter"`, `"unclosed_frontmatter"`,
#'   or `"yaml_parse_error"`).
#' @export
okf_parse_file <- function(path) {
  raw <- readLines(path, warn = FALSE, encoding = "UTF-8")
  txt <- paste(raw, collapse = "\n")
  i <- 1L; while (i <= length(raw) && !nzchar(trimws(raw[i]))) i <- i + 1L
  if (i > length(raw) || !grepl("^---\\s*$", raw[i]))
    return(list(meta = NULL, body = txt, err = "no_frontmatter"))
  fences <- which(grepl("^---\\s*$", raw))
  open  <- fences[fences >= i][1]
  close <- fences[fences > open][1]
  if (is.na(close)) return(list(meta = NULL, body = txt, err = "unclosed_frontmatter"))
  fm   <- paste(raw[(open + 1):(close - 1)], collapse = "\n")
  body <- if (close < length(raw)) paste(raw[(close + 1):length(raw)], collapse = "\n") else ""
  meta <- tryCatch(yaml::yaml.load(fm), error = function(e) NULL)
  if (is.null(meta)) return(list(meta = NULL, body = body, err = "yaml_parse_error"))
  list(meta = meta, body = body, err = NA_character_)
}

#' Extract markdown link targets from a concept body (OKF cross-links, sec. 4).
#'
#' @param body Concept body text.
#' @return Character vector of raw link targets (as written).
#' @export
okf_extract_links <- function(body) {
  regs <- regmatches(body, gregexpr("\\]\\(\\s*([^)\\s]+)", body, perl = TRUE))[[1]]
  if (!length(regs)) return(character(0))
  sub("^\\]\\(\\s*", "", regs)
}

.okf_norm <- function(p) {
  parts <- strsplit(gsub("\\\\", "/", p), "/", fixed = TRUE)[[1]]
  out <- character(0)
  for (s in parts) {
    if (s == "" || s == ".") next
    if (s == "..") { if (length(out)) out <- out[-length(out)]; next }
    out <- c(out, s)
  }
  paste(out, collapse = "/")
}

#' Resolve a markdown link target to a bundle-relative concept path.
#'
#' @param raw Raw link target.
#' @param src_rel Bundle-relative path of the linking concept.
#' @param known Character vector of all known concept paths in the bundle.
#' @return The resolved bundle-relative path, or `NA` if it does not resolve.
#' @export
okf_resolve_link <- function(raw, src_rel, known) {
  t <- sub("#.*$", "", raw)
  if (startsWith(t, "/")) cand <- sub("^/", "", t)
  else { d <- dirname(src_rel); cand <- if (d == ".") t else file.path(d, t) }
  cand <- .okf_norm(cand)
  if (cand %in% known) cand else NA_character_
}

.is_external <- function(raw) grepl("^[a-zA-Z][a-zA-Z0-9+.-]*:", sub("#.*$", "", raw))

#' Read an OKF bundle from a directory into an in-memory representation.
#'
#' @param root Path to the bundle directory.
#' @param bundle_id Optional stable id; defaults to a hash of the root path.
#' @param source_kind How the bundle was obtained (e.g. `"dir"`).
#' @return A list with `bundle_id`, `root`, `okf_version`, `source_kind`,
#'   `concepts` (parsed per-file records), and `known` (all concept paths).
#' @export
okf_read <- function(root, bundle_id = NULL, source_kind = "dir") {
  root  <- normalizePath(root, winslash = "/", mustWork = TRUE)
  files <- list.files(root, pattern = "\\.md$", recursive = TRUE, full.names = TRUE)
  rel_of <- function(f) {
    f <- normalizePath(f, winslash = "/")
    sub("^/", "", substr(f, nchar(root) + 1L, nchar(f)))  # root is a clean prefix
  }
  concepts <- lapply(files, function(f) {
    p <- okf_parse_file(f)
    list(path = rel_of(f), reserved = basename(f) %in% OKF_RESERVED,
         type = .s(p$meta$type), title = .s(p$meta$title),
         description = .s(p$meta$description), resource = .s(p$meta$resource),
         tags = p$meta$tags, timestamp = .s(p$meta$timestamp),
         body = p$body, frontmatter = p$meta, parse_error = p$err,
         links_raw = okf_extract_links(p$body),
         content_hash = digest::digest(p$body, algo = "sha1", serialize = FALSE))
  })
  known <- vapply(concepts, function(c) c$path, character(1))
  idx <- Filter(function(c) c$path == "index.md", concepts)
  okf_version <- if (length(idx)) .s(idx[[1]]$frontmatter$okf_version) else NA_character_
  if (is.null(bundle_id)) bundle_id <- digest::digest(root, algo = "sha1")
  list(bundle_id = bundle_id, root = root, okf_version = okf_version,
       source_kind = source_kind, concepts = concepts, known = known)
}

#' Build the concept graph (resolved and broken links) for a bundle.
#'
#' @param rd A bundle as returned by [okf_read()].
#' @return A data.frame with `src_path`, `dst_raw`, `dst_path`, `resolved`.
#' @export
okf_links <- function(rd) {
  rows <- list()
  for (c in rd$concepts) for (raw in c$links_raw) {
    if (.is_external(raw)) next
    dst <- okf_resolve_link(raw, c$path, rd$known)
    rows[[length(rows) + 1]] <- data.frame(src_path = c$path, dst_raw = raw,
      dst_path = dst, resolved = !is.na(dst), stringsAsFactors = FALSE)
  }
  if (!length(rows)) return(data.frame(src_path = character(), dst_raw = character(),
    dst_path = character(), resolved = logical()))
  do.call(rbind, rows)
}

#' Validate a bundle against the OKF v0.1 conformance rules (permissively).
#'
#' Hard rules (severity `error`): parseable frontmatter, non-empty `type`. Soft
#' findings (severity `warn`): missing recommended fields, non-ISO timestamps,
#' broken links. Never rejects the bundle -- returns findings.
#'
#' @param rd A bundle as returned by [okf_read()].
#' @return A data.frame with `path`, `severity`, `rule`, `message`.
#' @export
okf_validate <- function(rd) {
  rows <- list()
  add <- function(path, sev, rule, msg)
    rows[[length(rows) + 1]] <<- data.frame(path = path, severity = sev,
      rule = rule, message = msg, stringsAsFactors = FALSE)
  for (c in rd$concepts) {
    if (c$reserved) next
    if (!is.na(c$parse_error)) { add(c$path, "error", "frontmatter_unparseable",
      paste0("no parseable frontmatter (", c$parse_error, ")")); next }
    if (is.na(c$type) || !nzchar(c$type))
      add(c$path, "error", "missing_type", "frontmatter has no non-empty type")
    if (is.na(c$title))       add(c$path, "warn", "missing_title", "recommended field title absent")
    if (is.na(c$description)) add(c$path, "warn", "missing_description", "recommended field description absent")
    if (is.na(c$timestamp))   add(c$path, "warn", "missing_timestamp", "recommended field timestamp absent")
    else if (!grepl("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$", c$timestamp))
      add(c$path, "warn", "timestamp_not_iso8601", paste("timestamp not ISO-8601:", c$timestamp))
  }
  lk <- okf_links(rd)
  if (nrow(lk)) for (i in which(!lk$resolved))
    add(lk$src_path[i], "warn", "broken_link", paste("unresolved link:", lk$dst_raw[i]))
  # orphan concepts (Karpathy-style lint): non-reserved, parseable, with no
  # inbound resolved link from anywhere (including index.md).
  inbound <- if (nrow(lk)) unique(lk$dst_path[lk$resolved]) else character(0)
  for (c in rd$concepts) {
    if (c$reserved || !is.na(c$parse_error)) next
    if (!(c$path %in% inbound)) add(c$path, "warn", "orphan", "no inbound links (orphan concept)")
  }
  if (!length(rows)) return(data.frame(path = character(), severity = character(),
    rule = character(), message = character()))
  do.call(rbind, rows)
}

.okf_source_kind <- function(source) {
  s <- sub("[?#].*$", "", source)
  if (grepl("\\.zip$", s, ignore.case = TRUE)) "zip"
  else if (grepl("\\.(tar\\.gz|tgz|tar|tar\\.bz2)$", s, ignore.case = TRUE)) "tar"
  else if (grepl("\\.git$", s) || grepl("^git@", source) ||
           grepl("^https?://(www\\.)?(github|gitlab|bitbucket)\\.", s)) "git"
  else stop("cannot determine source kind (expected a dir, git URL, or tar/zip): ", source)
}

# Resolve the bundle root inside an extracted/cloned tree: honor an explicit
# subdir, else descend through single wrapper dirs (e.g. a GitHub tarball's
# `repo-branch/`) until markdown files appear.
.okf_bundle_root <- function(base, subdir = NULL) {
  if (!is.null(subdir) && nzchar(subdir)) return(file.path(base, subdir))
  cur <- base
  for (i in 1:6) {
    entries <- list.files(cur)                       # excludes hidden (skips .git)
    has_md <- any(grepl("\\.md$", entries, ignore.case = TRUE))
    dirs <- entries[dir.exists(file.path(cur, entries))]
    if (!has_md && length(dirs) == 1) cur <- file.path(cur, dirs) else break
  }
  cur
}

#' Materialize an OKF bundle from a directory, git URL, or tar/zip archive.
#'
#' Local directories are used in place. Git URLs (github/gitlab/bitbucket, `.git`,
#' or `git@`) are shallow-cloned. Tar/zip archives (local path or `http(s)` URL)
#' are downloaded if remote and extracted. The caller MUST invoke the returned
#' `cleanup()` when done to remove any temporary files.
#'
#' @param source A directory path, git URL, or tar/zip path/URL.
#' @param subdir Optional bundle path within the cloned/extracted tree.
#' @param branch Optional git branch or tag (git sources only).
#' @return A list with `dir` (the resolved bundle directory), `source_kind`
#'   (`"dir"`/`"git"`/`"tar"`/`"zip"`), and `cleanup` (a function).
#' @export
okf_fetch <- function(source, subdir = NULL, branch = NULL) {
  if (dir.exists(source))
    return(list(dir = normalizePath(source, winslash = "/"),
                source_kind = "dir", cleanup = function() invisible()))
  kind <- .okf_source_kind(source)
  tmp  <- tempfile("okf_"); dir.create(tmp)
  cleanup <- function() unlink(tmp, recursive = TRUE, force = TRUE)
  base <- tryCatch({
    if (kind == "git") {
      args <- c("clone", "--depth", "1")
      if (!is.null(branch)) args <- c(args, "--branch", branch)
      args <- c(args, source, file.path(tmp, "repo"))
      if (system2("git", args, stdout = FALSE, stderr = FALSE) != 0)
        stop("git clone failed (is git installed?): ", source)
      file.path(tmp, "repo")
    } else {
      local <- source
      if (grepl("^https?://", source)) {
        local <- file.path(tmp, basename(sub("[?#].*$", "", source)))
        utils::download.file(source, local, mode = "wb", quiet = TRUE)
      }
      ex <- file.path(tmp, "x"); dir.create(ex)
      # Reject path-traversal members (.. component or absolute path) before
      # extracting anything, since R's unzip/untar don't guarantee sanitization.
      members <- if (kind == "zip") utils::unzip(local, list = TRUE)$Name
                 else utils::untar(local, list = TRUE)
      if (any(grepl("(^|/)\\.\\.(/|$)", members) |
              grepl("^(/|\\\\|[A-Za-z]:)", members)))
        stop("archive contains unsafe paths (path traversal)")
      if (kind == "zip") utils::unzip(local, exdir = ex) else utils::untar(local, exdir = ex)
      ex
    }
  }, error = function(e) { cleanup(); stop(conditionMessage(e)) })
  list(dir = .okf_bundle_root(base, subdir), source_kind = kind, cleanup = cleanup)
}

#' Ingest an OKF bundle into a DuckDB catalog.
#'
#' Reads, validates, and loads the bundle into the `okf_bundle`, `okf_concept`,
#' `okf_link`, and `okf_validation` tables of a (file or in-memory) DuckDB
#' database.
#'
#' @param root A bundle directory path, a git URL, a tar/zip path or URL, or a
#'   bundle list from [okf_read()]. Non-directory sources are fetched via
#'   [okf_fetch()] and cleaned up afterwards.
#' @param db_path DuckDB path; defaults to in-memory `":memory:"`.
#' @param ingested_at Optional ISO-8601 timestamp; defaults to the current time.
#' @param bundle_id Optional stable bundle id.
#' @param source_kind How the bundle was obtained (e.g. `"dir"`); auto-set for
#'   fetched sources.
#' @param subdir Optional bundle path within a cloned/extracted source.
#' @param branch Optional git branch or tag (git sources only).
#' @param incremental Only rewrite concepts whose `content_hash` changed since a
#'   prior ingest of the same bundle into `db_path` (added/removed handled too);
#'   links and validation are always recomputed (they are graph-global). Falls
#'   back to a full load if the bundle is not already present. The `summary`
#'   then includes `changed`/`added`/`removed`/`cached` counts.
#' @return A list with the open `con`, the `bundle_id`, and a `summary`
#'   (counts, conformance, link totals). The caller owns/closes `con`.
#' @export
okf_ingest <- function(root, db_path = ":memory:", ingested_at = NULL,
                       bundle_id = NULL, source_kind = "dir",
                       subdir = NULL, branch = NULL, incremental = FALSE) {
  if (is.character(root) && length(root) == 1L && !dir.exists(root)) {
    f <- okf_fetch(root, subdir = subdir, branch = branch)
    on.exit(f$cleanup(), add = TRUE)
    rd <- okf_read(f$dir, bundle_id = bundle_id, source_kind = f$source_kind)
  } else {
    rd <- if (is.list(root) && !is.null(root$concepts)) root
          else okf_read(root, bundle_id = bundle_id, source_kind = source_kind)
  }
  val <- okf_validate(rd)
  lk  <- okf_links(rd)
  if (is.null(ingested_at)) ingested_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  err_paths <- unique(val$path[val$severity == "error"])
  non_reserved <- Filter(function(c) !c$reserved, rd$concepts)
  n_conf <- sum(vapply(non_reserved, function(c) !(c$path %in% err_paths), logical(1)))

  con <- DBI::dbConnect(duckdb::duckdb(), db_path)
  for (stmt in Filter(nzchar, trimws(strsplit(OKF_SCHEMA, ";")[[1]])))
    DBI::dbExecute(con, stmt)

  bid <- rd$bundle_id
  prior <- DBI::dbGetQuery(con, "SELECT path, content_hash FROM okf_concept WHERE bundle_id = ?",
                           params = list(bid))
  incr <- isTRUE(incremental) && nrow(prior) > 0

  # Per-concept rows for the whole bundle.
  cdf <- do.call(rbind, lapply(rd$concepts, function(c) data.frame(
    bundle_id = bid, path = c$path, reserved = c$reserved, type = c$type,
    title = c$title, description = c$description, resource = c$resource,
    tags = if (is.null(c$tags)) NA_character_ else as.character(jsonlite::toJSON(c$tags)),
    timestamp = c$timestamp, body = c$body,
    frontmatter = as.character(jsonlite::toJSON(c$frontmatter %||% list(), auto_unbox = TRUE, null = "null")),
    parse_error = c$parse_error, content_hash = c$content_hash, stringsAsFactors = FALSE)))

  inc_stats <- NULL
  if (incr) {
    cur <- setNames(cdf$content_hash, cdf$path); old <- setNames(prior$content_hash, prior$path)
    changed <- intersect(names(cur), names(old)); changed <- changed[cur[changed] != old[changed]]
    added   <- setdiff(names(cur), names(old))
    removed <- setdiff(names(old), names(cur))
    write_paths <- c(changed, added)
    if (length(c(changed, removed)))
      DBI::dbExecute(con, sprintf("DELETE FROM okf_concept WHERE bundle_id = ? AND path IN (%s)",
        paste(sprintf("'%s'", gsub("'", "''", c(changed, removed))), collapse = ",")), params = list(bid))
    if (length(write_paths)) DBI::dbAppendTable(con, "okf_concept", cdf[cdf$path %in% write_paths, , drop = FALSE])
    inc_stats <- list(changed = length(changed), added = length(added),
                      removed = length(removed), cached = length(intersect(names(cur), names(old))) - length(changed))
  } else {
    # Full (re)load: idempotent replace of any prior rows for this bundle.
    for (t in c("okf_bundle", "okf_concept", "okf_link", "okf_validation"))
      DBI::dbExecute(con, sprintf("DELETE FROM %s WHERE bundle_id = ?", t), params = list(bid))
    DBI::dbAppendTable(con, "okf_concept", cdf)
  }

  # Bundle row + graph-global tables: always rewritten to current state.
  DBI::dbExecute(con, "DELETE FROM okf_bundle WHERE bundle_id = ?", params = list(bid))
  DBI::dbAppendTable(con, "okf_bundle", data.frame(
    bundle_id = bid, root = rd$root, okf_version = rd$okf_version,
    source_kind = rd$source_kind, ingested_at = ingested_at,
    n_concepts = length(non_reserved), n_conformant = n_conf,
    conformant = sum(val$severity == "error") == 0, stringsAsFactors = FALSE))
  DBI::dbExecute(con, "DELETE FROM okf_link WHERE bundle_id = ?", params = list(bid))
  DBI::dbExecute(con, "DELETE FROM okf_validation WHERE bundle_id = ?", params = list(bid))
  if (nrow(lk)) DBI::dbAppendTable(con, "okf_link", data.frame(
    bundle_id = bid, src_path = lk$src_path, dst_raw = lk$dst_raw,
    dst_path = lk$dst_path, resolved = lk$resolved, stringsAsFactors = FALSE))
  if (nrow(val)) DBI::dbAppendTable(con, "okf_validation", data.frame(
    bundle_id = bid, path = val$path, severity = val$severity,
    rule = val$rule, message = val$message, stringsAsFactors = FALSE))

  list(con = con, bundle_id = bid, summary = c(list(
    n_files = length(rd$concepts), n_concepts = length(non_reserved), n_conformant = n_conf,
    conformant = sum(val$severity == "error") == 0,
    errors = sum(val$severity == "error"), warnings = sum(val$severity == "warn"),
    links_total = nrow(lk), links_broken = sum(!lk$resolved)), inc_stats))
}

#' Query helpers over an ingested OKF catalog.
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param term Search term for [okf_search()] (matched against concept bodies).
#' @return A data.frame: concepts ([okf_concepts]), link edges ([okf_graph_df]),
#'   validation findings ([okf_findings]), or body matches ([okf_search]).
#' @name okf_query
#' @export
okf_concepts <- function(con) DBI::dbGetQuery(con, "SELECT * FROM okf_concept ORDER BY path")
#' @rdname okf_query
#' @export
okf_graph_df <- function(con) DBI::dbGetQuery(con, "SELECT * FROM okf_link")
#' @rdname okf_query
#' @export
okf_findings <- function(con) DBI::dbGetQuery(con, "SELECT * FROM okf_validation ORDER BY severity, path")
#' @rdname okf_query
#' @export
okf_search   <- function(con, term) DBI::dbGetQuery(con, sprintf(
  "SELECT path, type, title FROM okf_concept WHERE body ILIKE '%%%s%%' ORDER BY path",
  gsub("'", "''", term)))

# ============================================================================
# Embeddings / RAG layer (the "+queryable index" option). Pluggable embedder;
# brute-force cosine search via DuckDB's native list_cosine_similarity (no
# extension required). The default embedder is local Ollama nomic-embed-text.
# ============================================================================

#' Split a concept body into chunks on paragraph boundaries.
#'
#' @param body Concept body text.
#' @param target_chars Approximate maximum chunk size in characters.
#' @return Character vector of chunks.
#' @export
okf_chunk_body <- function(body, target_chars = 600L) {
  paras <- trimws(strsplit(body %||% "", "\n[ \t]*\n", perl = TRUE)[[1]])
  paras <- paras[nzchar(paras)]
  chunks <- character(0); cur <- ""
  for (p in paras) {
    if (!nzchar(cur)) cur <- p
    else if (nchar(cur) + nchar(p) + 2 <= target_chars) cur <- paste(cur, p, sep = "\n\n")
    else { chunks <- c(chunks, cur); cur <- p }
  }
  if (nzchar(cur)) chunks <- c(chunks, cur)
  chunks
}

#' Build an embedder backed by a local Ollama embeddings model.
#'
#' An embedder is a function of `texts` returning a list of numeric vectors.
#' Swap in any such function (e.g. an OpenAI client) for [okf_embed()] /
#' [okf_rag()].
#'
#' @param model Ollama embedding model name.
#' @param url Ollama base URL (defaults to the `OLLAMA_URL` env var or localhost).
#' @return A function `texts -> list(numeric)`. Requires the httr2 package.
#' @export
okf_ollama_embedder <- function(model = "nomic-embed-text",
                                url = Sys.getenv("OLLAMA_URL", "http://localhost:11434")) {
  if (!requireNamespace("httr2", quietly = TRUE)) stop("okf_ollama_embedder needs the httr2 package")
  function(texts) lapply(texts, function(t) {
    r <- httr2::request(paste0(url, "/api/embeddings")) |>
      httr2::req_body_json(list(model = model, prompt = t)) |>
      httr2::req_timeout(120) |> httr2::req_perform()
    as.numeric(httr2::resp_body_json(r)$embedding)
  })
}

.okf_vec_lit <- function(v) paste0("[", paste(vapply(v, function(z) sprintf("%.8g", z), ""),
                                              collapse = ","), "]::FLOAT[]")

#' Chunk and embed concept bodies into the catalog for semantic search.
#'
#' Populates `okf_chunk` with one row per chunk plus its embedding vector and
#' the concept's `content_hash`. By default replaces all chunks. With
#' `incremental = TRUE`, only concepts whose `content_hash` differs from what was
#' last embedded are re-embedded (and removed concepts' chunks are dropped) --
#' the expensive embedder calls are skipped for unchanged concepts.
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param embedder An embedder function; defaults to [okf_ollama_embedder()].
#' @param target_chars Approximate chunk size in characters.
#' @param incremental Re-embed only concepts whose content changed.
#' @return The number of chunks (re)written this call (invisibly usable as an integer).
#' @export
okf_embed <- function(con, embedder = NULL, target_chars = 600L, incremental = FALSE) {
  if (is.null(embedder)) embedder <- okf_ollama_embedder()
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS okf_chunk (bundle_id TEXT, path TEXT, chunk_id INTEGER, text TEXT, embedding FLOAT[], content_hash TEXT)")
  cs <- DBI::dbGetQuery(con, "SELECT bundle_id, path, body, content_hash FROM okf_concept WHERE reserved = FALSE ORDER BY path")
  if (incremental) {
    have <- DBI::dbGetQuery(con, "SELECT DISTINCT path, content_hash FROM okf_chunk")
    havemap <- setNames(have$content_hash, have$path)
    # drop chunks for concepts that are gone or whose content changed
    stale <- union(setdiff(have$path, cs$path),
                   cs$path[vapply(seq_len(nrow(cs)), function(i)
                     !identical(unname(havemap[cs$path[i]]), cs$content_hash[i]), logical(1))])
    if (length(stale)) DBI::dbExecute(con, sprintf("DELETE FROM okf_chunk WHERE path IN (%s)",
      paste(sprintf("'%s'", gsub("'", "''", stale)), collapse = ",")))
    todo <- cs[cs$path %in% stale | !(cs$path %in% have$path), , drop = FALSE]
    cs <- todo
  } else {
    DBI::dbExecute(con, "DELETE FROM okf_chunk")
  }
  n <- 0L
  for (i in seq_len(nrow(cs))) {
    chs <- okf_chunk_body(cs$body[i], target_chars)
    if (!length(chs)) next
    embs <- embedder(chs)
    for (k in seq_along(chs)) {
      DBI::dbExecute(con, sprintf("INSERT INTO okf_chunk VALUES (?,?,?,?, %s, ?)", .okf_vec_lit(embs[[k]])),
                     params = list(cs$bundle_id[i], cs$path[i], k, chs[k], cs$content_hash[i]))
      n <- n + 1L
    }
  }
  n
}

#' Assemble an index-first, link-following slice of a bundle as one markdown
#' blob for direct LLM consumption.
#'
#' This is the OKF / "LLM wiki" consume primitive (Karpathy): hand the agent
#' `index.md` plus the relevant concept(s) and their link-neighborhood to read
#' directly. It uses the concept graph -- **no embeddings, no vector search**.
#' With `start`, it walks the (undirected) link graph from that concept to
#' `depth`; without `start`, it packs all concepts. Output is capped to roughly
#' `max_tokens` (estimated at ~4 chars/token).
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param start Optional concept path to center the neighborhood on.
#' @param depth Link-graph radius around `start` (ignored when `start` is NULL).
#' @param max_tokens Approximate output budget.
#' @param include_index Prepend `index.md` (the map) when present.
#' @return A list with `text` (the markdown blob), `included`/`omitted` concept
#'   paths, and `est_tokens`.
#' @export
okf_context <- function(con, start = NULL, depth = 1L, max_tokens = 8000L, include_index = TRUE) {
  cps <- DBI::dbGetQuery(con, "SELECT path, reserved, title, body FROM okf_concept")
  lks <- DBI::dbGetQuery(con, "SELECT src_path, dst_path FROM okf_link WHERE resolved")
  nonres <- cps$path[!as.logical(cps$reserved)]

  adj <- list()
  if (nrow(lks)) for (i in seq_len(nrow(lks))) {
    adj[[lks$src_path[i]]] <- unique(c(adj[[lks$src_path[i]]], lks$dst_path[i]))
    adj[[lks$dst_path[i]]] <- unique(c(adj[[lks$dst_path[i]]], lks$src_path[i]))
  }

  if (!is.null(start)) {
    if (!(start %in% cps$path)) stop("start concept not found: ", start)
    sel <- start; seen <- start; frontier <- start; d <- 0L
    while (d < depth && length(frontier)) {
      nb <- setdiff(unique(unlist(adj[frontier])), seen)
      sel <- c(sel, nb); seen <- c(seen, nb); frontier <- nb; d <- d + 1L
    }
    sel <- sel[sel %in% nonres]
  } else sel <- sort(nonres)

  est <- function(s) ceiling(nchar(s) / 4)
  root <- tryCatch(DBI::dbGetQuery(con, "SELECT root FROM okf_bundle LIMIT 1")$root,
                   error = function(e) "bundle")
  out <- sprintf("# OKF context -- %s\n", basename(root %||% "bundle"))
  used <- est(out); inc <- character(0); omit <- character(0)
  add_sec <- function(label, body) {
    s <- sprintf("\n## %s\n\n%s\n", label, body %||% "")
    if (used + est(s) <= max_tokens) { out <<- paste0(out, s); used <<- used + est(s); TRUE } else FALSE
  }
  if (include_index) {
    idx <- cps[cps$path == "index.md", ]
    if (nrow(idx)) add_sec("index.md", idx$body[1])
  }
  for (p in sel) {
    row <- cps[cps$path == p, ]
    label <- if (!is.na(row$title[1]) && nzchar(row$title[1])) sprintf("%s (%s)", row$title[1], p) else p
    if (add_sec(label, row$body[1])) inc <- c(inc, p) else omit <- c(omit, p)
  }
  list(text = out, included = inc, omitted = omit, est_tokens = used)
}

#' Semantic search over an embedded catalog.
#'
#' Embeds `query` and returns the top-k most cosine-similar chunks (via DuckDB's
#' native `list_cosine_similarity`). Run [okf_embed()] first.
#'
#' @param con An open DuckDB connection to an embedded okf catalog.
#' @param query Query string.
#' @param embedder An embedder function; defaults to [okf_ollama_embedder()].
#' @param k Number of results to return.
#' @return A data.frame with `path`, `title`, `chunk_id`, `score`, `text`.
#' @export
okf_rag <- function(con, query, embedder = NULL, k = 5L) {
  if (is.null(embedder)) embedder <- okf_ollama_embedder()
  qv <- embedder(query)[[1]]
  DBI::dbGetQuery(con, sprintf(
    "SELECT ch.path, c.title, ch.chunk_id,
            list_cosine_similarity(ch.embedding, %s) AS score, ch.text
     FROM okf_chunk ch JOIN okf_concept c USING (bundle_id, path)
     WHERE ch.embedding IS NOT NULL ORDER BY score DESC LIMIT %d",
    .okf_vec_lit(qv), as.integer(k)))
}
