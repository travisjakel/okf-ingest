# ============================================================================
# okf -- HTML rendering (a thin "render for viewing" layer over an OKF catalog)
#
# Turns an ingested OKF bundle into either a navigable static site (one
# self-contained .html per concept, links rewritten so you click through the
# graph) or a single self-contained .html (concepts become anchored sections,
# intra-bundle links jump to anchors). No JavaScript, inline CSS -- copy the
# output anywhere and open it.
#
# Public API:
#   okf_html(con, out, single = FALSE, site_title = NULL) -> list(files, ...)
#
# Mirrors py/okf/html.py (keep CSS + link rules in sync). Body markdown is
# rendered with the commonmark package (a thin Suggests dependency).
# ============================================================================

# Inline stylesheet, mirrored in py/okf/html.py (.OKF_CSS). Minimal, no JS.
OKF_CSS <- "
:root{--fg:#1f2328;--mut:#656d76;--bg:#fff;--accent:#0969da;--line:#d0d7de;--code:#f6f8fa;--warn:#9a6700}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif}
main.okf{max-width:860px;margin:0 auto;padding:2rem 1.25rem 4rem}
.okf-meta{display:flex;flex-wrap:wrap;gap:.4rem;align-items:center;margin:0 0 .25rem;font-size:.8rem}
.okf-chip{display:inline-block;padding:.08rem .5rem;border:1px solid var(--line);border-radius:999px;color:var(--mut)}
.okf-chip.type{border-color:var(--accent);color:var(--accent);font-weight:600}
.okf-desc{color:var(--mut);margin:.25rem 0 1.25rem;font-size:.95rem}
.okf section{border-top:1px solid var(--line);padding-top:2rem;margin-top:2rem}
.okf section:first-of-type{border-top:0;padding-top:0;margin-top:0}
h1,h2,h3,h4{line-height:1.25;margin-top:1.6rem}
h1{font-size:1.8rem;margin-top:.4rem}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
a.okf-broken{color:var(--warn);text-decoration:line-through;cursor:help}
code{background:var(--code);padding:.12em .35em;border-radius:6px;font-size:.88em}
pre{background:var(--code);padding:1rem;border-radius:8px;overflow:auto}
pre code{background:none;padding:0}
table{border-collapse:collapse;width:100%;margin:1rem 0;font-size:.92rem}
th,td{border:1px solid var(--line);padding:.4rem .6rem;text-align:left}
th{background:var(--code)}
blockquote{margin:1rem 0;padding:.2rem 1rem;border-left:4px solid var(--line);color:var(--mut)}
.okf-foot{margin-top:3rem;padding-top:1rem;border-top:1px solid var(--line);font-size:.8rem;color:var(--mut)}
.okf-foot .bad{color:var(--warn)}
.okf-nav{font-size:.85rem;margin-bottom:1.5rem}
.okf-nav a{margin-right:.75rem}
"

`%|NA|%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a)) b else a

.okf_esc <- function(s) {
  s <- gsub("&", "&amp;", s, fixed = TRUE)
  s <- gsub("<", "&lt;", s, fixed = TRUE)
  gsub(">", "&gt;", s, fixed = TRUE)
}

# Stable anchor id for single-file mode (also used to name nothing else).
.okf_slug <- function(path) {
  s <- tolower(sub("\\.md$", "", path))
  s <- gsub("[^a-z0-9]+", "-", s)
  gsub("(^-+|-+$)", "", s)
}

# Path from a concept's directory to a target concept path (both bundle-
# relative, POSIX). Yields page-relative links so the site works under file://
# regardless of how the source wrote them (relative or root-absolute).
.okf_relpath <- function(from_dir, to) {
  fp <- if (nzchar(from_dir)) strsplit(from_dir, "/", fixed = TRUE)[[1]] else character(0)
  tp <- strsplit(to, "/", fixed = TRUE)[[1]]
  common <- 0L; n <- min(length(fp), length(tp))
  while (common < n && fp[common + 1L] == tp[common + 1L]) common <- common + 1L
  out <- c(rep("..", length(fp) - common), tp[(common + 1L):length(tp)])
  if (!length(out)) to else paste(out, collapse = "/")
}

# Map a single href value to its rendered form. Internal `.md` links are
# rewritten to a page-relative `.html` path (site) or `#anchor` (single);
# external/asset/anchor links pass through. Unresolved internal `.md` links are
# left for the page footer badge to flag (site keeps a dead .html target;
# single is a no-op anchor).
.okf_map_href <- function(raw, page, known, single) {
  if (grepl("^[a-zA-Z][a-zA-Z0-9+.-]*:", raw) || startsWith(raw, "#") || startsWith(raw, "//"))
    return(raw)
  sp   <- strsplit(raw, "#", fixed = TRUE)[[1]]
  base <- sp[1]
  frag <- if (length(sp) > 1) paste0("#", paste(sp[-1], collapse = "#")) else ""
  if (!grepl("\\.md$", base)) return(raw)              # image / asset / non-concept
  res <- okf_resolve_link(base, page, known)
  if (single) {
    if (!is.na(res)) return(paste0("#", .okf_slug(res)))
    return(raw)                                        # broken -> harmless dead anchor
  }
  d <- dirname(page); if (d == ".") d <- ""
  if (!is.na(res)) return(paste0(.okf_relpath(d, sub("\\.md$", ".html", res)), frag))
  paste0(sub("\\.md$", ".html", base), frag)           # broken -> dead .html, footer flags it
}

# Rewrite every href attribute in a rendered HTML fragment.
.okf_rewrite_hrefs <- function(html, page, known, single) {
  m <- gregexpr('href="([^"]*)"', html, perl = TRUE)[[1]]
  if (m[1] == -1L) return(html)
  cs <- attr(m, "capture.start"); cl <- attr(m, "capture.length")
  pieces <- character(0); prev <- 1L
  for (i in seq_along(m)) {
    hs <- cs[i]; hl <- cl[i]
    raw <- substr(html, hs, hs + hl - 1L)
    new <- .okf_map_href(raw, page, known, single)
    pieces <- c(pieces, substr(html, prev, hs - 1L), new)
    prev <- hs + hl
  }
  paste0(c(pieces, substr(html, prev, nchar(html))), collapse = "")
}

.okf_render_body <- function(body) {
  commonmark::markdown_html(body %|NA|% "", extensions = TRUE, smart = FALSE)
}

# The chip/metadata bar + description shown above each concept's body.
.okf_meta_bar <- function(row, status) {
  chips <- character(0)
  if (!is.na(row$type) && nzchar(row$type))
    chips <- c(chips, sprintf('<span class="okf-chip type">%s</span>', .okf_esc(row$type)))
  if (!is.null(status) && !is.na(status) && nzchar(status))
    chips <- c(chips, sprintf('<span class="okf-chip">%s</span>', .okf_esc(status)))
  if (!is.na(row$timestamp) && nzchar(row$timestamp))
    chips <- c(chips, sprintf('<span class="okf-chip">%s</span>', .okf_esc(substr(row$timestamp, 1, 10))))
  tags <- tryCatch(jsonlite::fromJSON(row$tags), error = function(e) NULL)
  if (length(tags))
    chips <- c(chips, sprintf('<span class="okf-chip">%s</span>',
                              .okf_esc(paste(as.character(tags), collapse = " \u00b7 "))))
  bar <- if (length(chips)) sprintf('<div class="okf-meta">%s</div>', paste(chips, collapse = "")) else ""
  desc <- if (!is.na(row$description) && nzchar(row$description))
    sprintf('<p class="okf-desc">%s</p>', .okf_esc(row$description)) else ""
  paste0(bar, desc)
}

# Resolve a known concept path to its rendered href for the current mode.
.okf_href_for <- function(target, page, single) {
  if (single) return(paste0("#", .okf_slug(target)))
  d <- dirname(page); if (d == ".") d <- ""
  .okf_relpath(d, sub("\\.md$", ".html", target))
}

# "Linked from" backlinks line (the wiki's key navigation affordance).
.okf_backlinks_html <- function(page, blmap, titlemap, single) {
  srcs <- blmap[[page]]
  if (!length(srcs)) return("")
  items <- vapply(srcs, function(s) sprintf('<a href="%s">%s</a>',
    .okf_href_for(s, page, single), .okf_esc(titlemap[[s]] %|NA|% s)), "")
  sprintf('<div class="okf-foot">Linked from: %s</div>', paste(items, collapse = " \u00b7 "))
}

# Per-page footer badge derived from the validation findings (broken / orphan).
.okf_footer <- function(page, val) {
  v <- val[val$path == page, , drop = FALSE]
  nb <- sum(v$rule == "broken_link")
  orph <- any(v$rule == "orphan")
  if (nb == 0 && !orph) return('<div class="okf-foot">\u2713 no link issues</div>')
  bits <- character(0)
  if (nb > 0) bits <- c(bits, sprintf('<span class="bad">\u26a0 %d broken link%s</span>', nb, if (nb == 1) "" else "s"))
  if (orph)  bits <- c(bits, '<span class="bad">orphan (no inbound links)</span>')
  sprintf('<div class="okf-foot">%s</div>', paste(bits, collapse = " \u00b7 "))
}

.okf_doc <- function(title, body_inner) {
  paste0("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n",
         "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
         "<title>", .okf_esc(title), "</title>\n<style>", OKF_CSS, "</style>\n</head>\n<body>\n",
         "<main class=\"okf\">\n", body_inner, "\n</main>\n</body>\n</html>\n")
}

#' Render an ingested OKF catalog to HTML for viewing.
#'
#' Two modes. As a navigable **site** (`single = FALSE`, the default), writes one
#' self-contained `.html` per concept under `out/` (mirroring the bundle's
#' directory tree) plus an `index.html` landing page; internal `.md` links are
#' rewritten to `.html`. As a **single file** (`single = TRUE`), writes one
#' self-contained `.html` at path `out`, with each concept an anchored
#' `<section>` and intra-bundle links rewritten to in-page anchors. No
#' JavaScript; CSS is inlined so output is portable. Reserved concepts
#' (`index.md`, `log.md`) are rendered too. Bodies are rendered with the
#' commonmark package; broken/orphan links are surfaced in a per-page footer
#' badge from the validation findings.
#'
#' @param con An open DuckDB connection to an okf catalog (from [okf_ingest()]).
#' @param out Output directory (site mode) or output `.html` file path (single).
#' @param single Emit one self-contained file instead of a per-concept site.
#' @param site_title Optional title for the landing page / single-file header;
#'   defaults to the bundle directory name.
#' @return A list with `files` (paths written), `n_concepts`, and `mode`
#'   (invisibly).
#' @export
okf_html <- function(con, out, single = FALSE, site_title = NULL) {
  if (!requireNamespace("commonmark", quietly = TRUE))
    stop("okf_html needs the commonmark package (install.packages('commonmark'))")
  cps <- DBI::dbGetQuery(con, "SELECT path, reserved, type, title, description, tags, timestamp, body, frontmatter FROM okf_concept ORDER BY path")
  val <- tryCatch(DBI::dbGetQuery(con, "SELECT path, rule FROM okf_validation"),
                  error = function(e) data.frame(path = character(), rule = character()))
  if (!nrow(cps)) stop("catalog has no concepts to render")
  known <- cps$path
  bl <- tryCatch(DBI::dbGetQuery(con, "SELECT DISTINCT src_path, dst_path FROM okf_link WHERE resolved ORDER BY src_path"),
                 error = function(e) data.frame(src_path = character(), dst_path = character()))
  blmap <- if (nrow(bl)) split(bl$src_path, bl$dst_path) else list()
  titlemap <- setNames(as.list(cps$title), cps$path)
  root <- tryCatch(DBI::dbGetQuery(con, "SELECT root FROM okf_bundle LIMIT 1")$root,
                   error = function(e) NA_character_)
  if (is.null(site_title) || is.na(site_title %|NA|% NA))
    site_title <- basename(root %|NA|% "OKF bundle")

  status_of <- function(fm) tryCatch(.s(jsonlite::fromJSON(fm)$status), error = function(e) NA_character_)

  # Render each concept body once (HTML), with links rewritten for the mode.
  render_one <- function(i) {
    row <- cps[i, , drop = FALSE]
    h <- .okf_render_body(row$body)
    .okf_rewrite_hrefs(h, row$path, known, single)
  }

  if (single) {
    order_idx <- c(which(cps$path == "index.md"),
                   which(cps$path != "index.md" & cps$path != "log.md"),
                   which(cps$path == "log.md"))
    nav <- paste0('<div class="okf-nav"><strong>', .okf_esc(site_title), '</strong> &mdash; ',
                  paste(vapply(order_idx, function(i) {
                    t <- cps$title[i] %|NA|% cps$path[i]
                    sprintf('<a href="#%s">%s</a>', .okf_slug(cps$path[i]), .okf_esc(t))
                  }, ""), collapse = ""), "</div>")
    secs <- vapply(order_idx, function(i) {
      row <- cps[i, , drop = FALSE]
      sprintf('<section id="%s">\n%s\n%s\n%s\n%s\n</section>',
              .okf_slug(row$path), .okf_meta_bar(row, status_of(row$frontmatter)),
              render_one(i), .okf_footer(row$path, val),
              .okf_backlinks_html(row$path, blmap, titlemap, TRUE))
    }, "")
    html <- .okf_doc(site_title, paste0(nav, "\n", paste(secs, collapse = "\n")))
    dir.create(dirname(normalizePath(out, mustWork = FALSE)), showWarnings = FALSE, recursive = TRUE)
    writeLines(html, out, useBytes = TRUE)
    cat(sprintf("[okf_html] wrote single file %s (%d concepts)\n", out, nrow(cps)))
    return(invisible(list(files = out, n_concepts = nrow(cps), mode = "single")))
  }

  # Site mode: one file per concept, mirroring the bundle tree.
  dir.create(out, showWarnings = FALSE, recursive = TRUE)
  files <- character(0)
  has_index <- "index.md" %in% cps$path
  for (i in seq_len(nrow(cps))) {
    row <- cps[i, , drop = FALSE]
    rel  <- sub("\\.md$", ".html", row$path)
    dest <- file.path(out, rel)
    dir.create(dirname(dest), showWarnings = FALSE, recursive = TRUE)
    title <- row$title %|NA|% row$path
    inner <- paste0(.okf_meta_bar(row, status_of(row$frontmatter)), "\n",
                    render_one(i), "\n", .okf_footer(row$path, val), "\n",
                    .okf_backlinks_html(row$path, blmap, titlemap, FALSE))
    writeLines(.okf_doc(title, inner), dest, useBytes = TRUE)
    files <- c(files, dest)
  }
  # Synthesize index.html when the bundle has no index.md.
  if (!has_index) {
    items <- vapply(seq_len(nrow(cps)), function(i) {
      rel <- sub("\\.md$", ".html", cps$path[i])
      sprintf('<li><a href="%s">%s</a> <span class="okf-desc">%s</span></li>',
              rel, .okf_esc(cps$title[i] %|NA|% cps$path[i]), .okf_esc(cps$description[i] %|NA|% ""))
    }, "")
    inner <- paste0("<h1>", .okf_esc(site_title), "</h1>\n<ul>", paste(items, collapse = ""), "</ul>")
    dest <- file.path(out, "index.html")
    writeLines(.okf_doc(site_title, inner), dest, useBytes = TRUE)
    files <- c(files, dest)
  }
  cat(sprintf("[okf_html] wrote %d files under %s\n", length(files), out))
  invisible(list(files = files, n_concepts = nrow(cps), mode = "site"))
}
