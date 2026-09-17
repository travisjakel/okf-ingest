# ============================================================================
# OKF v0.2 trust, lifecycle, provenance and attested-computation semantics.
#
# Everything here reads frontmatter families the core already preserves
# verbatim and DERIVES meaning from them, which SPEC 11 asks consumers to do:
# "consumers SHOULD derive trust tiers and staleness only from the fields
# specified here". None of it changes `okf_validate()`, so the fixture-locked
# core stays identical across all five bindings -- these are R/Python only.
# ============================================================================

# SPEC 5.4: the lifecycle vocabulary is closed. A value outside it is NOT a
# lifecycle status and must not be guessed at: the R_Files wiki, for one, uses
# `status: active|settled|open|archived` (plus some free prose) on 218
# concepts, a producer extension that collides with this key. Such a value is
# treated as absent and reported once as `info`.
OKF_STATUS <- c("draft", "stable", "deprecated")

.okf_status <- function(fm) {
  s <- .s(fm$status)
  if (is.na(s)) return(NA_character_)
  if (s %in% OKF_STATUS) s else NA_character_
}

# A v0.2 family key whose VALUE is not the v0.2 shape. Producer extensions
# reuse these names -- the R_Files wiki writes `status: active` and
# `sources: 3` (a count) -- so every family reader has to check the shape
# before indexing it. Returns a list of entry-maps, or an empty list, and
# never errors: `$` on an atomic vector is a hard error, not a warning, and
# one such concept would otherwise abort an ingest of the whole bundle.
.okf_maplist <- function(x) {
  if (is.null(x) || !is.list(x)) return(list())
  if (!is.null(x[["by"]]) || !is.null(x[["at"]]) || !is.null(x[["resource"]]) ||
      !is.null(x[["name"]])) return(list(x))     # a bare mapping is one entry
  Filter(is.list, x)
}

# True when the key is present but carries something other than the v0.2 shape.
.okf_family_misshaped <- function(x) {
  !is.null(x) && length(.okf_maplist(x)) == 0L
}

# SPEC 5.2: `verified` is a list of {by, at}; a single verifier MAY be written
# as a bare mapping, and a consumer MUST treat that as a one-element list.
.okf_verified <- function(fm) .okf_maplist(fm$verified)

# Parse an ISO-8601 instant with an explicit offset (NA when it is not one).
# Deliberately strict: SPEC 5 says every timestamp-valued key carries an
# explicit UTC offset, and a bare local datetime has no defined instant.
.okf_instant <- function(x) {
  if (is.null(x) || length(x) != 1L) return(as.POSIXct(NA))
  if (is.na(x) || !nzchar(x)) return(as.POSIXct(NA))
  if (!.okf_is_iso8601(x)) return(as.POSIXct(NA))
  y <- sub("Z$", "+0000", x)
  y <- sub("([+-][0-9]{2}):([0-9]{2})$", "\\1\\2", y)
  tryCatch(as.POSIXct(y, format = "%Y-%m-%dT%H:%M:%OS%z", tz = "UTC"),
           error = function(e) as.POSIXct(NA))
}

# SPEC 5.2: "how recently" is the latest `at`. Compare parsed INSTANTS, not
# the strings: for one instant, an offset form sorts above a Z form lexically,
# so a string max can report the wrong verification as the most recent.
.okf_latest <- function(ats) {
  ats <- ats[!is.na(ats) & nzchar(ats)]
  if (!length(ats)) return(NA_character_)
  ts <- as.POSIXct(vapply(ats, function(a) as.numeric(.okf_instant(a)), 0),
                   origin = "1970-01-01", tz = "UTC")
  if (all(is.na(ts))) return(ats[length(ats)])
  ats[which.max(ts)]
}

#' Derive the OKF v0.2 trust and lifecycle state of every concept.
#'
#' Trust tiers follow SPEC 5.3 exactly: no `verified` key is `unverified`,
#' `verified` by non-`human:` actors only is `machine-confirmed`, and any
#' `human:<id>` verifier is `human-reviewed`. Staleness follows SPEC 5.5: a
#' concept is stale when `now >= stale_after`, an absolute instant, which keeps
#' the decision a plain comparison with no reference to when it was read.
#'
#' @param rd A bundle as returned by [okf_read()].
#' @param now Reference time as an ISO-8601 string; defaults to the current UTC
#'   time. Supply it to keep a report reproducible.
#' @return A data.frame with one row per concept: `path`, `status` (`NA` when
#'   absent or outside the SPEC 5.4 vocabulary), `status_raw`, `stale_after`,
#'   `is_stale`, `trust_tier`, `verified_at` (the latest), `verified_by`,
#'   `generated_by`, `n_verified`.
#' @export
okf_trust <- function(rd, now = NULL) {
  ref <- if (is.null(now)) format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC") else now
  now_t <- .okf_instant(ref)
  rows <- lapply(rd$concepts, function(c) {
    fm <- c$frontmatter
    vs <- .okf_verified(fm)
    ats <- vapply(vs, function(v) .s(v[["at"]]), "")
    bys <- vapply(vs, function(v) .s(v[["by"]]), "")
    tier <- if (!length(vs)) "unverified"
            else if (any(grepl("^human:", bys))) "human-reviewed"
            else "machine-confirmed"
    ok_at <- ats[!is.na(ats)]
    sa <- .s(fm$stale_after)
    sa_t <- .okf_instant(sa)
    data.frame(
      path = c$path,
      status = .okf_status(fm),
      status_raw = .s(fm$status),
      stale_after = sa,
      is_stale = !is.na(sa_t) && !is.na(now_t) && now_t >= sa_t,
      trust_tier = tier,
      verified_at = .okf_latest(ok_at),
      verified_by = if (length(bys)) paste(bys[!is.na(bys)], collapse = "; ") else NA_character_,
      generated_by = .s(if (is.list(fm$generated)) fm$generated[["by"]]),
      n_verified = length(vs),
      stringsAsFactors = FALSE)
  })
  if (!length(rows)) return(data.frame(path = character(), status = character(),
    status_raw = character(), stale_after = character(), is_stale = logical(),
    trust_tier = character(), verified_at = character(), verified_by = character(),
    generated_by = character(), n_verified = integer()))
  do.call(rbind, rows)
}

# Markdown footnote definition labels in a body: `[^label]: text`.
.okf_footnote_labels <- function(body) {
  pat <- "(?m)^\\[\\^([^]]+)\\]:"
  m <- regmatches(body, gregexpr(pat, body, perl = TRUE))[[1]]
  if (!length(m)) return(character(0))
  sub("^\\[\\^(.*)\\]:$", "\\1", m)
}

#' Extract the `sources` provenance entries of a bundle (SPEC 5.1).
#'
#' One row per `sources[]` entry, with the per-source credibility signals kept
#' as authored -- the spec records signals and refuses to store a score, so this
#' does not compute one either. `cited` records whether the body attributes a
#' claim to the entry through a markdown footnote whose label is the entry's
#' `id`: the join key the spec defines, keyed rather than positional so that
#' reordering the list cannot silently misattribute.
#'
#' @param rd A bundle as returned by [okf_read()].
#' @return A data.frame with `path`, `idx`, `id`, `resource`, `title`, `author`,
#'   `usage_count`, `last_modified`, `is_scope`, `cited`.
#' @export
okf_sources <- function(rd) {
  rows <- list()
  for (c in rd$concepts) {
    ss <- .okf_maplist(c$frontmatter$sources)
    if (!length(ss)) next
    labels <- .okf_footnote_labels(c$body)
    for (k in seq_along(ss)) {
      s <- ss[[k]]
      id <- .s(s[["id"]]); res <- .s(s[["resource"]])
      rows[[length(rows) + 1]] <- data.frame(
        path = c$path, idx = k, id = id, resource = res,
        title = .s(s[["title"]]), author = .s(s[["author"]]),
        usage_count = .s(s[["usage_count"]]), last_modified = .s(s[["last_modified"]]),
        is_scope = !is.na(res) && !.is_external(res) && .okf_is_scope(res),
        cited = !is.na(id) && id %in% labels,
        stringsAsFactors = FALSE)
    }
  }
  if (!length(rows)) return(data.frame(path = character(), idx = integer(),
    id = character(), resource = character(), title = character(),
    author = character(), usage_count = character(), last_modified = character(),
    is_scope = logical(), cited = logical()))
  do.call(rbind, rows)
}

# Regex constants for the Attested Computation readers. Defined once, as
# constants, because these patterns decide what counts as a sanctioned
# computation.
RE_COMPUTATION_H <- "^#+[[:space:]]+Computation[[:space:]]*$"
RE_HEADING       <- "^#+[[:space:]]"
RE_FENCE         <- "^[[:space:]]*```"
RE_WORD_END      <- "\\b"
RE_DOLLAR        <- "[$]"
RE_MUST_OPEN     <- "\\{\\{[[:space:]]*"
RE_MUST_CLOSE    <- "[[:space:]]*\\}\\}"
RE_WS_RUN        <- "[[:space:]]+"
NL               <- "\n"

#' Read the Attested Computation contracts in a bundle (SPEC 10).
#'
#' Reads and binds only -- nothing here executes or attests anything. The
#' computation is either an inline fenced block under a `# Computation` heading
#' (SPEC 10.3) or a file named by the `computation` path field; declaring both,
#' or neither, is a defect [okf_doctor()] reports.
#'
#' @param rd A bundle as returned by [okf_read()].
#' @param now Reference time passed through to [okf_trust()].
#' @return A data.frame with `path`, `title`, `runtime`, `computation_path`,
#'   `computation` (the text, from whichever form is present), `form`
#'   (`inline`/`file`/`none`/`both`), `n_parameters`, `parameters` (JSON),
#'   `executor`, `receipt` (JSON), `attester`, plus `status`, `stale_after`,
#'   `is_stale` and `trust_tier` from [okf_trust()].
#' @export
okf_computations <- function(rd, now = NULL) {
  tr <- okf_trust(rd, now = now)
  targets <- if (is.null(rd$files)) rd$known else rd$files
  rows <- list()
  for (c in rd$concepts) {
    if (!identical(.s(c$type), "Attested Computation")) next
    fm <- c$frontmatter
    cp <- .s(fm$computation)
    inline <- .okf_computation_fence(c$body)
    form <- if (!is.na(cp) && !is.na(inline)) "both"
            else if (!is.na(cp)) "file"
            else if (!is.na(inline)) "inline" else "none"
    txt <- if (form %in% c("file", "both")) {
      r <- okf_resolve_path(cp, c$path, targets)
      if (!is.na(r$path))
        tryCatch(paste(readLines(file.path(rd$root, r$path), warn = FALSE), collapse = NL),
                 error = function(e) NA_character_)
      else NA_character_
    } else inline
    ps <- .okf_maplist(fm$parameters)
    t <- tr[tr$path == c$path, , drop = FALSE]
    rows[[length(rows) + 1]] <- data.frame(
      path = c$path, title = .s(c$title), runtime = .s(fm$runtime),
      computation_path = cp, computation = txt, form = form,
      n_parameters = length(ps),
      parameters = as.character(jsonlite::toJSON(ps, auto_unbox = TRUE)),
      executor = .s(if (is.list(fm$executor)) fm$executor[["resource"]]),
      receipt = as.character(jsonlite::toJSON(
        if (is.list(fm$executor)) fm$executor[["receipt"]] else NULL)),
      attester = .s(if (is.list(fm$attester)) fm$attester[["resource"]]),
      status = if (nrow(t)) t$status else NA_character_,
      stale_after = if (nrow(t)) t$stale_after else NA_character_,
      is_stale = if (nrow(t)) t$is_stale else NA,
      trust_tier = if (nrow(t)) t$trust_tier else NA_character_,
      stringsAsFactors = FALSE)
  }
  if (!length(rows)) return(data.frame(path = character(), title = character(),
    runtime = character(), computation_path = character(), computation = character(),
    form = character(), n_parameters = integer(), parameters = character(),
    executor = character(), receipt = character(), attester = character(),
    status = character(), stale_after = character(), is_stale = logical(),
    trust_tier = character()))
  do.call(rbind, rows)
}

# The single fenced block under a `# Computation` heading (SPEC 10.3). Returns
# the fence CONTENTS, or NA when the heading or the fence is absent.
.okf_computation_fence <- function(body) {
  lines <- strsplit(body, NL, fixed = TRUE)[[1]]
  h <- grep(RE_COMPUTATION_H, lines)
  if (!length(h) || h[1] >= length(lines)) return(NA_character_)
  rest <- lines[(h[1] + 1L):length(lines)]
  nxt <- grep(RE_HEADING, rest)
  if (length(nxt)) rest <- rest[seq_len(nxt[1] - 1L)]
  open <- grep(RE_FENCE, rest)
  if (length(open) < 2L) return(NA_character_)
  if (open[2] - open[1] < 2L) return("")
  paste(rest[(open[1] + 1L):(open[2] - 1L)], collapse = NL)
}

#' Bind parameter values into an Attested Computation, deterministically.
#'
#' The agent supplies *values* for the declared `parameters` and MUST NOT author
#' or edit the computation (SPEC 10.3). Binding the computation with those
#' values into the executable artifact is the consumer's job, and the attester
#' independently re-derives the same binding to compare against what actually
#' ran. Shipping that derivation here -- in the deterministic layer, with no
#' execution -- is what lets an attester be three lines: bind, canonicalise,
#' compare.
#'
#' Substitution is textual and runtime-agnostic: every occurrence of `@name`,
#' `$name` or `\{\{name\}\}` becomes the supplied value. An undeclared parameter
#' name and a missing required parameter are both errors, because a silent
#' partial binding is exactly the failure attestation exists to catch.
#'
#' @param contract One row of [okf_computations()].
#' @param params Named list of parameter values.
#' @return A list with `artifact` (the bound text), `canonical`, and `hash`
#'   (sha1 of the canonical form).
#' @export
okf_bind <- function(contract, params = list()) {
  if (is.data.frame(contract)) {
    if (nrow(contract) != 1L) stop("okf_bind() takes exactly one contract row")
    contract <- as.list(contract)
  }
  txt <- contract$computation
  if (is.null(txt) || is.na(txt)) stop("contract has no computation text")
  decl <- jsonlite::fromJSON(contract$parameters, simplifyDataFrame = FALSE)
  if (is.null(decl)) decl <- list()
  names_decl <- vapply(decl, function(p) as.character(p$name)[1], "")
  unknown <- setdiff(names(params), names_decl)
  if (length(unknown))
    stop("parameter(s) not declared by the contract: ", paste(unknown, collapse = ", "))
  for (p in decl) {
    req <- isTRUE(p$required) || identical(p$required, "true")
    if (req && !(p$name %in% names(params)))
      stop("required parameter missing: ", p$name)
  }
  for (nm in names_decl) {
    if (!(nm %in% names(params))) next
    v <- as.character(params[[nm]])[1]
    txt <- gsub(paste0("@", nm, RE_WORD_END), v, txt)
    txt <- gsub(paste0(RE_DOLLAR, nm, RE_WORD_END), v, txt)
    txt <- gsub(paste0(RE_MUST_OPEN, nm, RE_MUST_CLOSE), v, txt)
  }
  canon <- okf_canonicalize(txt)
  list(artifact = txt, canonical = canon,
       hash = digest::digest(canon, algo = "sha1", serialize = FALSE))
}

#' Canonicalize a computation artifact for comparison.
#'
#' Collapses runs of whitespace, trims each line and drops blank lines, so a
#' re-derived binding and a receipt's recorded artifact compare equal despite
#' formatting. Deliberately conservative: it does NOT touch case, comments or
#' token order, because a consumer that normalises too much stops detecting the
#' rewrite it exists to detect.
#'
#' @param txt Computation text.
#' @return The canonical form.
#' @export
okf_canonicalize <- function(txt) {
  lines <- strsplit(txt, NL, fixed = TRUE)[[1]]
  lines <- trimws(gsub(RE_WS_RUN, " ", lines))
  paste(lines[nzchar(lines)], collapse = NL)
}
