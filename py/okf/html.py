"""okf HTML rendering (Python) — mirrors the R binding's okf_html().

A thin "render for viewing" layer: turn an ingested OKF catalog into either a
navigable static site (one self-contained .html per concept, links rewritten so
you click through the graph) or a single self-contained .html (concepts become
anchored sections). No JavaScript, inline CSS — copy the output anywhere and
open it. Body markdown is rendered with the `markdown` package (the optional
`okf-ingest[html]` extra). Keep CSS + link rules in sync with r/okf/R/okf_html.R.
"""
from __future__ import annotations
import json, os, re
from typing import Optional

from . import okf as _okf

# Inline stylesheet, mirrored in r/okf/R/okf_html.R (OKF_CSS). Minimal, no JS.
OKF_CSS = """
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
"""

_SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
_HREF = re.compile(r'href="([^"]*)"')


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _slug(path: str) -> str:
    s = re.sub(r"\.md$", "", path).lower()
    return re.sub(r"(^-+|-+$)", "", re.sub(r"[^a-z0-9]+", "-", s))


def _relpath(from_dir: str, to: str) -> str:
    """Path from a concept's directory to a target concept path (both bundle-
    relative, POSIX). Yields page-relative links so the site works under file://
    regardless of how the source wrote them (relative or root-absolute)."""
    fp = from_dir.split("/") if from_dir else []
    tp = to.split("/")
    common = 0
    while common < min(len(fp), len(tp)) and fp[common] == tp[common]:
        common += 1
    out = [".."] * (len(fp) - common) + tp[common:]
    return "/".join(out) if out else to


def _map_href(raw: str, page: str, known: set, single: bool) -> str:
    """Internal `.md` links -> page-relative `.html` (site) or `#anchor`
    (single); external / asset / in-page-anchor links pass through. Unresolved
    internal `.md` links are left for the footer badge to flag."""
    if _SCHEME.match(raw) or raw.startswith("#") or raw.startswith("//"):
        return raw
    sp = raw.split("#", 1)
    base = sp[0]
    frag = f"#{sp[1]}" if len(sp) > 1 else ""
    if not base.endswith(".md"):
        return raw
    res = _okf.resolve_link(base, page, known)
    if single:
        return f"#{_slug(res)}" if res is not None else raw
    d = os.path.dirname(page)
    if res is not None:
        return _relpath(d, re.sub(r"\.md$", ".html", res)) + frag
    return re.sub(r"\.md$", ".html", base) + frag


def _rewrite_hrefs(html: str, page: str, known: set, single: bool) -> str:
    return _HREF.sub(lambda m: f'href="{_map_href(m.group(1), page, known, single)}"', html)


def _render_body(body: str) -> str:
    import markdown  # optional dep: pip install okf-ingest[html]
    return markdown.markdown(body or "", extensions=["tables", "fenced_code", "sane_lists"])


def _meta_bar(row: dict, status: Optional[str]) -> str:
    chips = []
    if row.get("type"):
        chips.append(f'<span class="okf-chip type">{_esc(row["type"])}</span>')
    if status:
        chips.append(f'<span class="okf-chip">{_esc(status)}</span>')
    if row.get("timestamp"):
        chips.append(f'<span class="okf-chip">{_esc(row["timestamp"][:10])}</span>')
    tags = row.get("tags")
    if tags:
        try:
            tl = json.loads(tags) if isinstance(tags, str) else tags
        except Exception:
            tl = None
        if tl:
            chips.append(f'<span class="okf-chip">{_esc(" · ".join(str(t) for t in tl))}</span>')
    bar = f'<div class="okf-meta">{"".join(chips)}</div>' if chips else ""
    desc = f'<p class="okf-desc">{_esc(row["description"])}</p>' if row.get("description") else ""
    return bar + desc


def _href_for(target: str, page: str, single: bool) -> str:
    if single:
        return "#" + _slug(target)
    return _relpath(os.path.dirname(page), re.sub(r"\.md$", ".html", target))


def _backlinks_html(page: str, blmap: dict, titlemap: dict, single: bool) -> str:
    srcs = blmap.get(page)
    if not srcs:
        return ""
    items = " · ".join(
        f'<a href="{_href_for(s, page, single)}">{_esc(titlemap.get(s) or s)}</a>' for s in srcs)
    return f'<div class="okf-foot">Linked from: {items}</div>'


def _footer(page: str, val: list) -> str:
    rules = [f["rule"] for f in val if f["path"] == page]
    nb = rules.count("broken_link")
    orph = "orphan" in rules
    if nb == 0 and not orph:
        return '<div class="okf-foot">✓ no link issues</div>'
    bits = []
    if nb:
        bits.append(f'<span class="bad">⚠ {nb} broken link{"" if nb == 1 else "s"}</span>')
    if orph:
        bits.append('<span class="bad">orphan (no inbound links)</span>')
    return f'<div class="okf-foot">{" · ".join(bits)}</div>'


def _doc(title: str, body_inner: str) -> str:
    return (
        '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{_esc(title)}</title>\n<style>{OKF_CSS}</style>\n</head>\n<body>\n"
        f'<main class="okf">\n{body_inner}\n</main>\n</body>\n</html>\n'
    )


def render_html(con, out: str, single: bool = False, site_title: Optional[str] = None) -> dict:
    """Render an ingested OKF catalog to HTML for viewing.

    Site mode (`single=False`, default): one self-contained `.html` per concept
    under `out/` (mirroring the bundle tree) + an `index.html` landing page;
    internal `.md` links become `.html`. Single mode (`single=True`): one
    self-contained `.html` at path `out`, each concept an anchored `<section>`,
    intra-bundle links jumping to anchors. No JS; CSS inlined. Returns a dict
    with `files`, `n_concepts`, `mode`.
    """
    cps = [dict(zip(["path", "reserved", "type", "title", "description", "tags",
                     "timestamp", "body", "frontmatter"], r))
           for r in con.execute(
               "SELECT path, reserved, type, title, description, tags, timestamp, body, "
               "frontmatter FROM okf_concept ORDER BY path").fetchall()]
    if not cps:
        raise ValueError("catalog has no concepts to render")
    val = [{"path": p, "rule": rl} for p, rl in
           con.execute("SELECT path, rule FROM okf_validation").fetchall()]
    known = {c["path"] for c in cps}
    blmap = {}
    for s, d in con.execute(
            "SELECT DISTINCT src_path, dst_path FROM okf_link WHERE resolved ORDER BY src_path").fetchall():
        blmap.setdefault(d, []).append(s)
    titlemap = {c["path"]: c["title"] for c in cps}
    row = con.execute("SELECT root FROM okf_bundle LIMIT 1").fetchone()
    root = row[0] if row else None
    if not site_title:
        site_title = os.path.basename(root) if root else "OKF bundle"

    def status_of(fm):
        try:
            return _okf._s(json.loads(fm).get("status"))
        except Exception:
            return None

    def render_one(c):
        return _rewrite_hrefs(_render_body(c["body"]), c["path"], known, single)

    by_path = {c["path"]: c for c in cps}

    if single:
        order = ([by_path["index.md"]] if "index.md" in by_path else []) + \
                [c for c in cps if c["path"] not in ("index.md", "log.md")] + \
                ([by_path["log.md"]] if "log.md" in by_path else [])
        nav_links = "".join(
            f'<a href="#{_slug(c["path"])}">{_esc(c["title"] or c["path"])}</a>' for c in order)
        nav = f'<div class="okf-nav"><strong>{_esc(site_title)}</strong> &mdash; {nav_links}</div>'
        secs = [
            f'<section id="{_slug(c["path"])}">\n{_meta_bar(c, status_of(c["frontmatter"]))}\n'
            f'{render_one(c)}\n{_footer(c["path"], val)}\n'
            f'{_backlinks_html(c["path"], blmap, titlemap, True)}\n</section>'
            for c in order
        ]
        html = _doc(site_title, nav + "\n" + "\n".join(secs))
        d = os.path.dirname(os.path.abspath(out))
        os.makedirs(d, exist_ok=True)
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(html)
        print(f"[render_html] wrote single file {out} ({len(cps)} concepts)")
        return {"files": [out], "n_concepts": len(cps), "mode": "single"}

    os.makedirs(out, exist_ok=True)
    files = []
    for c in cps:
        rel = re.sub(r"\.md$", ".html", c["path"])
        dest = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dest) or out, exist_ok=True)
        inner = (f'{_meta_bar(c, status_of(c["frontmatter"]))}\n{render_one(c)}\n'
                 f'{_footer(c["path"], val)}\n'
                 f'{_backlinks_html(c["path"], blmap, titlemap, False)}')
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(_doc(c["title"] or c["path"], inner))
        files.append(dest)
    if "index.md" not in by_path:
        def _li(c):
            href = re.sub(r"\.md$", ".html", c["path"])
            return (f'<li><a href="{href}">{_esc(c["title"] or c["path"])}</a> '
                    f'<span class="okf-desc">{_esc(c["description"] or "")}</span></li>')
        items = "".join(_li(c) for c in cps)
        dest = os.path.join(out, "index.html")
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(_doc(site_title, f"<h1>{_esc(site_title)}</h1>\n<ul>{items}</ul>"))
        files.append(dest)
    print(f"[render_html] wrote {len(files)} files under {out}")
    return {"files": files, "n_concepts": len(cps), "mode": "site"}
