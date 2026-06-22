# ============================================================================
# okf — Open Knowledge Format ingestion (R reference binding)
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
  text TEXT, embedding FLOAT[]);
"

# --- frontmatter parse ------------------------------------------------------
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

# --- markdown link extraction + resolution (OKF §4) -------------------------
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

okf_resolve_link <- function(raw, src_rel, known) {
  t <- sub("#.*$", "", raw)
  if (startsWith(t, "/")) cand <- sub("^/", "", t)
  else { d <- dirname(src_rel); cand <- if (d == ".") t else file.path(d, t) }
  cand <- .okf_norm(cand)
  if (cand %in% known) cand else NA_character_
}

.is_external <- function(raw) grepl("^[a-zA-Z][a-zA-Z0-9+.-]*:", sub("#.*$", "", raw))

# --- read a bundle ----------------------------------------------------------
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

# --- graph edges ------------------------------------------------------------
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

# --- conformance validation -------------------------------------------------
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
  if (!length(rows)) return(data.frame(path = character(), severity = character(),
    rule = character(), message = character()))
  do.call(rbind, rows)
}

# --- ingest to DuckDB catalog ----------------------------------------------
okf_ingest <- function(root, db_path = ":memory:", ingested_at = NULL,
                       bundle_id = NULL, source_kind = "dir") {
  rd  <- if (is.list(root) && !is.null(root$concepts)) root
         else okf_read(root, bundle_id = bundle_id, source_kind = source_kind)
  val <- okf_validate(rd)
  lk  <- okf_links(rd)
  if (is.null(ingested_at)) ingested_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  err_paths <- unique(val$path[val$severity == "error"])
  non_reserved <- Filter(function(c) !c$reserved, rd$concepts)
  n_conf <- sum(vapply(non_reserved, function(c) !(c$path %in% err_paths), logical(1)))

  con <- DBI::dbConnect(duckdb::duckdb(), db_path)
  for (stmt in Filter(nzchar, trimws(strsplit(OKF_SCHEMA, ";")[[1]])))
    DBI::dbExecute(con, stmt)

  DBI::dbAppendTable(con, "okf_bundle", data.frame(
    bundle_id = rd$bundle_id, root = rd$root, okf_version = rd$okf_version,
    source_kind = rd$source_kind, ingested_at = ingested_at,
    n_concepts = length(non_reserved), n_conformant = n_conf,
    conformant = sum(val$severity == "error") == 0, stringsAsFactors = FALSE))

  cdf <- do.call(rbind, lapply(rd$concepts, function(c) data.frame(
    bundle_id = rd$bundle_id, path = c$path, reserved = c$reserved, type = c$type,
    title = c$title, description = c$description, resource = c$resource,
    tags = if (is.null(c$tags)) NA_character_ else as.character(jsonlite::toJSON(c$tags)),
    timestamp = c$timestamp, body = c$body,
    frontmatter = as.character(jsonlite::toJSON(c$frontmatter %||% list(), auto_unbox = TRUE, null = "null")),
    parse_error = c$parse_error, content_hash = c$content_hash, stringsAsFactors = FALSE)))
  DBI::dbAppendTable(con, "okf_concept", cdf)

  if (nrow(lk)) DBI::dbAppendTable(con, "okf_link", data.frame(
    bundle_id = rd$bundle_id, src_path = lk$src_path, dst_raw = lk$dst_raw,
    dst_path = lk$dst_path, resolved = lk$resolved, stringsAsFactors = FALSE))
  if (nrow(val)) DBI::dbAppendTable(con, "okf_validation", data.frame(
    bundle_id = rd$bundle_id, path = val$path, severity = val$severity,
    rule = val$rule, message = val$message, stringsAsFactors = FALSE))

  list(con = con, bundle_id = rd$bundle_id, summary = list(
    n_files = length(rd$concepts), n_concepts = length(non_reserved), n_conformant = n_conf,
    conformant = sum(val$severity == "error") == 0,
    errors = sum(val$severity == "error"), warnings = sum(val$severity == "warn"),
    links_total = nrow(lk), links_broken = sum(!lk$resolved)))
}

# --- query helpers ----------------------------------------------------------
okf_concepts <- function(con) DBI::dbGetQuery(con, "SELECT * FROM okf_concept ORDER BY path")
okf_graph_df <- function(con) DBI::dbGetQuery(con, "SELECT * FROM okf_link")
okf_findings <- function(con) DBI::dbGetQuery(con, "SELECT * FROM okf_validation ORDER BY severity, path")
okf_search   <- function(con, term) DBI::dbGetQuery(con, sprintf(
  "SELECT path, type, title FROM okf_concept WHERE body ILIKE '%%%s%%' ORDER BY path",
  gsub("'", "''", term)))

# ============================================================================
# Embeddings / RAG layer (the "+queryable index" option). Pluggable embedder;
# brute-force cosine search via DuckDB's native list_cosine_similarity (no
# extension required). The default embedder is local Ollama nomic-embed-text.
# ============================================================================

# Split a concept body into ~target_chars chunks on paragraph boundaries.
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

# An embedder is function(texts) -> list of numeric vectors. Default hits the
# local Ollama embeddings API; swap in any function (OpenAI, etc.) for OSS use.
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

# Chunk + embed every non-reserved concept body into okf_chunk. Idempotent
# (replaces existing chunks). Returns the number of chunks written.
okf_embed <- function(con, embedder = NULL, target_chars = 600L) {
  if (is.null(embedder)) embedder <- okf_ollama_embedder()
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS okf_chunk (bundle_id TEXT, path TEXT, chunk_id INTEGER, text TEXT, embedding FLOAT[])")
  cs <- DBI::dbGetQuery(con, "SELECT bundle_id, path, body FROM okf_concept WHERE reserved = FALSE ORDER BY path")
  DBI::dbExecute(con, "DELETE FROM okf_chunk")
  n <- 0L
  for (i in seq_len(nrow(cs))) {
    chs <- okf_chunk_body(cs$body[i], target_chars)
    if (!length(chs)) next
    embs <- embedder(chs)
    for (k in seq_along(chs)) {
      DBI::dbExecute(con, sprintf("INSERT INTO okf_chunk VALUES (?,?,?,?, %s)", .okf_vec_lit(embs[[k]])),
                     params = list(cs$bundle_id[i], cs$path[i], k, chs[k]))
      n <- n + 1L
    }
  }
  n
}

# Semantic search: embed the query, return the top-k most similar chunks.
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
