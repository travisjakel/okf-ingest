# ============================================================================
# okf -- doctor: a DETERMINISTIC health / maintenance report for a bundle.
#
# Knowledge bases drift: links break when files move, timestamps go stale,
# concepts orphan. `okf_doctor()` is a one-shot health scan (reusing the
# validation findings already in the catalog plus a few maintenance checks),
# with a health score and CI-friendly exit semantics. `okf_doctor_fix()` applies
# ONLY unambiguously-safe repairs to the source files (normalize parseable
# non-ISO timestamps; re-point a broken link when exactly one basename matches)
# and reports every change. No LLM, no guessing -- mechanical fixes only.
#
# Mirrors py/okf/doctor.py.
# ============================================================================

#' Health / maintenance report for an ingested OKF catalog.
#'
#' Combines the validation findings already stored in the catalog (missing type,
#' broken links, orphans, non-ISO timestamps, ...) with maintenance checks
#' (duplicate titles; and, when `now` is supplied, future/stale timestamps), and
#' computes a health `score` = the percentage of non-reserved concepts with zero
#' findings. Fully deterministic.
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param now Optional ISO-8601 "current time" enabling stale/future-timestamp
#'   checks (kept explicit so the function stays deterministic; the CLI passes
#'   the wall clock).
#' @param stale_days Optional integer; with `now`, flag timestamps older than
#'   this many days.
#' @return A list with `score`, `n_concepts`, `n_healthy`, `n_error`, `n_warn`,
#'   `by_rule` (named counts), and `issues` (a data.frame of path/severity/rule/
#'   message).
#' @export
okf_doctor <- function(con, now = NULL, stale_days = NULL) {
  cps <- DBI::dbGetQuery(con, "SELECT path, reserved, title, timestamp FROM okf_concept ORDER BY path")
  nonres <- cps[!as.logical(cps$reserved), , drop = FALSE]
  val <- DBI::dbGetQuery(con, "SELECT path, severity, rule, message FROM okf_validation")
  if (!nrow(val)) val <- data.frame(path = character(), severity = character(),
                                    rule = character(), message = character(), stringsAsFactors = FALSE)
  add <- function(df, path, sev, rule, msg)
    rbind(df, data.frame(path = path, severity = sev, rule = rule, message = msg, stringsAsFactors = FALSE))

  # maintenance check: duplicate titles among non-reserved concepts
  tt <- nonres$title[!is.na(nonres$title) & nzchar(nonres$title)]
  for (d in names(which(table(tt) > 1)))
    for (p in nonres$path[which(!is.na(nonres$title) & nonres$title == d)])
      val <- add(val, p, "warn", "duplicate_title", paste0("title shared with another concept: ", d))

  # maintenance check: future / stale timestamps (only when a reference time is given)
  if (!is.null(now)) {
    now_t <- tryCatch(as.POSIXct(now, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), error = function(e) NA)
    if (!is.na(now_t)) for (i in seq_len(nrow(nonres))) {
      ts <- nonres$timestamp[i]
      if (is.na(ts) || !grepl("^\\d{4}-\\d{2}-\\d{2}T", ts)) next
      tv <- tryCatch(as.POSIXct(ts, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), error = function(e) NA)
      if (is.na(tv)) next
      if (tv > now_t) val <- add(val, nonres$path[i], "warn", "future_timestamp",
                                 paste("timestamp is in the future:", ts))
      else if (!is.null(stale_days) && as.numeric(now_t - tv, units = "days") > stale_days)
        val <- add(val, nonres$path[i], "warn", "stale_timestamp",
                   sprintf("timestamp older than %d days: %s", as.integer(stale_days), ts))
    }
  }

  flagged <- unique(val$path)
  n <- nrow(nonres); healthy <- sum(!(nonres$path %in% flagged))
  score <- if (n > 0) as.integer(round(100 * healthy / n)) else 100L
  by_rule <- if (nrow(val)) as.list(table(val$rule)) else list()
  list(score = score, n_concepts = n, n_healthy = healthy,
       n_error = sum(val$severity == "error"), n_warn = sum(val$severity == "warn"),
       by_rule = by_rule, issues = val[order(val$severity, val$path), , drop = FALSE])
}

# Try to parse a loosely-formatted date/time string to an ISO-8601 UTC stamp.
# Returns NA if it cannot be parsed unambiguously.
.okf_to_iso <- function(s) {
  s <- trimws(s)
  if (grepl("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$", s)) return(s)  # already ISO
  fmts_dt <- c("%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S")
  for (f in fmts_dt) { d <- tryCatch(as.POSIXct(s, format = f, tz = "UTC"), error = function(e) NA)
    if (!is.na(d)) return(format(d, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")) }
  fmts_d <- c("%Y-%m-%d", "%Y/%m/%d", "%m/%d/%Y", "%d %b %Y", "%B %d, %Y")
  for (f in fmts_d) { d <- tryCatch(as.Date(s, format = f), error = function(e) NA)
    if (!is.na(d)) return(paste0(format(d, "%Y-%m-%d"), "T00:00:00Z")) }
  NA_character_
}

#' Apply only unambiguously-safe maintenance fixes to a bundle's source files.
#'
#' Two mechanical, deterministic repairs (never invents content):
#' \itemize{
#'   \item **timestamps** -- a parseable non-ISO `timestamp:` is rewritten to ISO-8601.
#'   \item **moved links** -- a broken link whose basename matches *exactly one*
#'     concept is re-pointed to that concept (relative to the linking file).
#' }
#' Edits files in place. Anything ambiguous is left for [okf_doctor()] to report.
#'
#' @param root A bundle directory path.
#' @return A data.frame of changes (`path`, `kind`, `before`, `after`); zero rows
#'   if nothing was safely fixable.
#' @export
okf_doctor_fix <- function(root) {
  rd <- okf_read(root); lk <- okf_links(rd)
  known <- rd$known
  changes <- list()
  rec <- function(path, kind, before, after)
    changes[[length(changes) + 1]] <<- data.frame(path = path, kind = kind,
      before = before, after = after, stringsAsFactors = FALSE)
  fpath <- function(rel) file.path(root, rel)

  # 1) timestamp normalization (frontmatter line edit)
  for (c in rd$concepts) {
    if (c$reserved || is.na(c$timestamp)) next
    iso <- .okf_to_iso(c$timestamp)
    if (is.na(iso) || identical(iso, c$timestamp)) next
    lines <- readLines(fpath(c$path), warn = FALSE, encoding = "UTF-8")
    fences <- which(grepl("^---\\s*$", lines))
    if (length(fences) < 2) next
    block <- (fences[1] + 1):(fences[2] - 1)
    ti <- block[grepl("^\\s*timestamp\\s*:", lines[block])][1]
    if (is.na(ti)) next
    lines[ti] <- sub("(^\\s*timestamp\\s*:\\s*).*$", paste0("\\1", iso), lines[ti])
    writeLines(lines, fpath(c$path), useBytes = TRUE)
    rec(c$path, "timestamp", c$timestamp, iso)
  }

  # 2) moved-link repair (unique basename match)
  base_of <- function(p) basename(sub("#.*$", "", p))
  bn <- vapply(known, base_of, "")
  brk <- lk[!lk$resolved, , drop = FALSE]
  for (i in seq_len(nrow(brk))) {
    raw <- brk$dst_raw[i]; src <- brk$src_path[i]
    b <- base_of(raw); if (!nzchar(b)) next
    match <- known[bn == b]
    if (length(match) != 1) next                      # ambiguous or none -> report, don't guess
    d <- dirname(src); if (d == ".") d <- ""
    frag <- sub("^[^#]*", "", raw)
    newrel <- paste0(.okf_relpath(d, match), frag)
    txt <- paste(readLines(fpath(src), warn = FALSE, encoding = "UTF-8"), collapse = "\n")
    needle <- paste0("](", raw, ")"); repl <- paste0("](", newrel, ")")
    if (!grepl(needle, txt, fixed = TRUE)) next
    writeLines(strsplit(gsub(needle, repl, txt, fixed = TRUE), "\n", fixed = TRUE)[[1]],
               fpath(src), useBytes = TRUE)
    rec(src, "link", raw, newrel)
  }

  if (!length(changes)) return(data.frame(path = character(), kind = character(),
    before = character(), after = character(), stringsAsFactors = FALSE))
  do.call(rbind, changes)
}
