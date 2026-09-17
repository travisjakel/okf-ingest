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
#' broken links, orphans, non-ISO timestamps, ...) with maintenance checks:
#' duplicate titles; duplicate identity (the same normalized id/alias claimed
#' by more than one concept -- breaks by-name/wikilink resolution); hub
#' concentration (info severity: pages whose outbound links mostly point at
#' high in-degree hubs); and, when `now` is supplied, future/stale timestamps.
#' Health `score` = the percentage of non-reserved concepts with zero
#' error/warn findings -- `info` findings never affect it. Fully deterministic.
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param now Optional ISO-8601 "current time" enabling stale/future-timestamp
#'   checks (kept explicit so the function stays deterministic; the CLI passes
#'   the wall clock).
#' @param stale_days Optional integer; with `now`, flag timestamps older than
#'   this many days.
#' @return A list with `score`, `n_concepts`, `n_healthy`, `n_error`, `n_warn`,
#'   `n_info`, `by_rule` (named counts), and `issues` (a data.frame of
#'   path/severity/rule/message; severity is `error`, `warn`, or `info`).
#' @export
okf_doctor <- function(con, now = NULL, stale_days = NULL) {
  cps <- DBI::dbGetQuery(con, paste("SELECT path, reserved, title, timestamp,",
    "status, status_raw, stale_after, trust_tier FROM okf_concept ORDER BY path"))
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

  # maintenance check: duplicate identity -- the same normalized id/alias
  # claimed by more than one concept (breaks by-name/wikilink resolution)
  fmres <- DBI::dbGetQuery(con,
    "SELECT path, frontmatter FROM okf_concept WHERE reserved = FALSE ORDER BY path")
  normk <- function(x) gsub("[^a-z0-9]", "", tolower(as.character(x)))
  claims <- list()
  for (i in seq_len(nrow(fmres))) {
    fm <- tryCatch(jsonlite::fromJSON(fmres$frontmatter[i]), error = function(e) list())
    keys <- normk(c(if (!is.null(fm$id)) fm$id, unlist(fm$aliases)))
    for (kk in unique(keys[nzchar(keys)]))
      claims[[kk]] <- c(claims[[kk]], fmres$path[i])
  }
  for (kk in names(claims)) if (length(unique(claims[[kk]])) > 1)
    for (p in unique(claims[[kk]]))
      val <- add(val, p, "warn", "duplicate_identity",
                 paste0("id/alias '", kk, "' also claimed by: ",
                        paste(setdiff(unique(claims[[kk]]), p), collapse = ", ")))

  # maintenance check (info): hub concentration -- a page whose outbound links
  # mostly point at high in-degree hubs adds little distinct structure.
  # Info severity: reported, but does not count against the health score.
  lk2 <- DBI::dbGetQuery(con,
    "SELECT DISTINCT src_path, dst_path FROM okf_link WHERE resolved")
  if (nrow(lk2)) {
    indeg <- table(lk2$dst_path)
    pos <- sort(as.integer(indeg))
    q90 <- pos[max(1L, ceiling(0.9 * length(pos)))]
    hubs <- names(indeg)[as.integer(indeg) >= max(3L, q90)]
    outs <- split(lk2$dst_path, lk2$src_path)
    for (p in intersect(names(outs), nonres$path)) {
      dsts <- unique(outs[[p]])
      if (length(dsts) >= 3 && mean(dsts %in% hubs) >= 0.8)
        val <- add(val, p, "info", "hub_concentration",
                   sprintf("%d/%d outbound links point at hub pages", sum(dsts %in% hubs), length(dsts)))
    }
  }

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

  # ---- OKF v0.2 lifecycle, trust and attestation (SPEC 5, SPEC 10) ----------
  # SPEC 11: consumers SHOULD derive trust tiers and staleness only from the
  # fields specified there. These rules are that derivation, and nothing here
  # guesses at a value the spec does not define.

  # `status` outside the closed SPEC 5.4 vocabulary. Not a defect in the bundle
  # -- producer extensions legitimately reuse the key, and the R_Files wiki does
  # on 218 concepts -- but the consumer must say it is ignoring the value rather
  # than mapping it onto a lifecycle it does not mean.
  for (i in seq_len(nrow(nonres))) {
    raw <- nonres$status_raw[i]
    if (is.na(raw) || !nzchar(raw)) next
    if (!is.na(nonres$status[i])) next
    val <- add(val, nonres$path[i], "info", "status_not_spec_vocabulary",
               sprintf("status %s is not draft/stable/deprecated (SPEC 5.4); treated as absent", raw))
  }

  # The same collision, generalised: a v0.2 family key carrying something other
  # than the v0.2 shape. The R_Files wiki writes `sources: 3` (a count) as a
  # producer extension. Ignoring it is the spec-correct permissive behaviour,
  # but silence is how a consumer ends up looking like it read provenance it
  # never saw -- so say which key was skipped and why.
  fmj <- tryCatch(DBI::dbGetQuery(con,
    "SELECT path, frontmatter FROM okf_concept WHERE reserved = FALSE"),
    error = function(e) NULL)
  if (!is.null(fmj) && nrow(fmj)) for (i in seq_len(nrow(fmj))) {
    fm <- tryCatch(jsonlite::fromJSON(fmj$frontmatter[i], simplifyVector = FALSE),
                   error = function(e) NULL)
    if (!is.list(fm)) next
    for (key in c("sources", "verified", "generated", "executor", "attester", "parameters")) {
      if (!.okf_family_misshaped(fm[[key]])) next
      val <- add(val, fmj$path[i], "info", "family_not_spec_shape",
                 sprintf("%s is present but not in the SPEC 5/10 shape; treated as absent", key))
    }
  }

  # SPEC 5.5 staleness: an absolute instant, so this is a plain comparison.
  # It supersedes the age-heuristic `stale_timestamp` above, which guesses.
  if (!is.null(now)) {
    now_i <- .okf_instant(now)
    if (!is.na(now_i)) for (i in seq_len(nrow(nonres))) {
      sa <- nonres$stale_after[i]
      sa_i <- .okf_instant(sa)
      if (is.na(sa_i)) next
      if (now_i >= sa_i)
        val <- add(val, nonres$path[i], "warn", "stale_after_passed",
                   sprintf("stale_after %s has passed; re-verify before serving (SPEC 10.5)", sa))
    }
  }

  # A live concept depending on a deprecated one. The dependency is real and
  # the target says not to use it, which is a fact only the graph can see.
  dep <- nonres$path[!is.na(nonres$status) & nonres$status == "deprecated"]
  if (length(dep)) {
    lk <- DBI::dbGetQuery(con, "SELECT src_path, dst_path, kind FROM okf_link WHERE resolved")
    st <- setNames(nonres$status, nonres$path)
    for (i in seq_len(nrow(lk))) {
      if (!(lk$dst_path[i] %in% dep)) next
      s_st <- st[lk$src_path[i]]
      if (!is.na(s_st) && s_st == "deprecated") next   # deprecated -> deprecated is fine
      val <- add(val, lk$src_path[i], "warn", "deprecated_inbound",
                 sprintf("%s reference to a deprecated concept: %s", lk$kind[i], lk$dst_path[i]))
    }
  }

  # SPEC 5.1 per-claim attribution: the footnote label is the join key into
  # sources[].id. Both halves of a broken join are worth saying out loud.
  src <- tryCatch(DBI::dbGetQuery(con, "SELECT path, id, cited FROM okf_source"),
                  error = function(e) NULL)
  if (!is.null(src) && nrow(src)) for (i in seq_len(nrow(src))) {
    if (is.na(src$id[i]) || !nzchar(src$id[i])) next
    if (!as.logical(src$cited[i]))
      val <- add(val, src$path[i], "info", "source_id_uncited",
                 sprintf("sources[].id %s is never cited by a [^%s] footnote", src$id[i], src$id[i]))
  }

  # SPEC 10.2/10.3 contract defects on an Attested Computation.
  cmp <- tryCatch(DBI::dbGetQuery(con, paste("SELECT path, runtime, form, n_parameters,",
                    "parameters, executor, attester FROM okf_computation")),
                  error = function(e) NULL)
  if (!is.null(cmp) && nrow(cmp)) for (i in seq_len(nrow(cmp))) {
    pth <- cmp$path[i]
    if (is.na(cmp$runtime[i]) || !nzchar(cmp$runtime[i]))
      val <- add(val, pth, "warn", "computation_no_runtime",
                 "runtime is REQUIRED on an Attested Computation (SPEC 10.2)")
    if (identical(cmp$form[i], "none"))
      val <- add(val, pth, "warn", "computation_absent",
                 "neither a # Computation fence nor a computation: path (SPEC 10.3)")
    if (identical(cmp$form[i], "both"))
      val <- add(val, pth, "warn", "computation_ambiguous",
                 "both a # Computation fence and a computation: path; SPEC 10.3 allows one")
    if (is.na(cmp$attester[i]) || !nzchar(cmp$attester[i]))
      val <- add(val, pth, "info", "computation_no_attester",
                 "no attester: a run of this computation cannot be checked (SPEC 10.5)")
    ps <- tryCatch(jsonlite::fromJSON(cmp$parameters[i], simplifyDataFrame = FALSE),
                   error = function(e) NULL)
    for (prm in (ps %||% list())) {
      if (is.null(prm$type) || !nzchar(as.character(prm$type)[1]))
        val <- add(val, pth, "warn", "parameter_untyped",
                   sprintf("parameter %s has no type; the typed surface is what makes attestation mechanical (SPEC 10.3)",
                           as.character(prm$name)[1]))
    }
  }

  flagged <- unique(val$path[val$severity != "info"])   # info never hurts the score
  n <- nrow(nonres); healthy <- sum(!(nonres$path %in% flagged))
  score <- if (n > 0) as.integer(round(100 * healthy / n)) else 100L
  by_rule <- if (nrow(val)) as.list(table(val$rule)) else list()
  list(score = score, n_concepts = n, n_healthy = healthy,
       n_error = sum(val$severity == "error"), n_warn = sum(val$severity == "warn"),
       n_info = sum(val$severity == "info"),
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
#' Edits files in place. Anything ambiguous is left for [okf_doctor()] to
#' report. Pages carrying `reviewed: true` in frontmatter are human-validated
#' and are never modified (protected pages).
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

  # Pages marked `reviewed: true` are human-validated -- automated maintenance
  # must not touch them (Obsidian-plugin-style protected pages).
  is_reviewed <- function(c) isTRUE(c$frontmatter$reviewed)
  reviewed <- vapply(rd$concepts, is_reviewed, logical(1))
  names(reviewed) <- vapply(rd$concepts, function(c) c$path, character(1))

  # 1) timestamp normalization (frontmatter line edit)
  for (c in rd$concepts) {
    if (c$reserved || is.na(c$timestamp) || is_reviewed(c)) next
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
    if (isTRUE(reviewed[[src]])) next          # protected page: report, don't edit
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
