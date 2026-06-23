# ============================================================================
# okf -- graph affordances over an ingested catalog (all DETERMINISTIC; no LLM)
#
# The catalog already holds the concept graph (okf_link). These helpers surface
# it the way a wiki wants to be navigated and visualized:
#   okf_backlinks(con, path)   -> who links TO a concept ("linked from")
#   okf_impact(con, path)      -> inbound / outbound / transitive ripple
#   okf_clusters(con)          -> community label per concept (label propagation)
#   okf_graph_json(con)        -> portable {nodes, edges} for any visualizer
#   okf_graph_html(con, out)   -> one self-contained force-directed page (no CDN)
#
# Mirrors py/okf/graph.py. Pure graph code -- no embeddings, no model calls.
# ============================================================================

# Undirected adjacency over RESOLVED links, plus the non-reserved node set.
.okf_adj <- function(con) {
  cps <- DBI::dbGetQuery(con, "SELECT path, reserved, type, title, tags FROM okf_concept ORDER BY path")
  lks <- DBI::dbGetQuery(con, "SELECT src_path, dst_path FROM okf_link WHERE resolved")
  adj <- list()
  for (p in cps$path) adj[[p]] <- character(0)
  if (nrow(lks)) for (i in seq_len(nrow(lks))) {
    s <- lks$src_path[i]; d <- lks$dst_path[i]
    adj[[s]] <- unique(c(adj[[s]], d))
    adj[[d]] <- unique(c(adj[[d]], s))
  }
  list(cps = cps, adj = adj)
}

#' Concepts that link to a given concept ("linked from" / backlinks).
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param path Bundle-relative concept path.
#' @return Character vector of source concept paths (resolved inbound links).
#' @export
okf_backlinks <- function(con, path) {
  DBI::dbGetQuery(con, "SELECT DISTINCT src_path FROM okf_link WHERE resolved AND dst_path = ? ORDER BY src_path",
                  params = list(path))$src_path
}

#' Link-impact ("ripple") of a concept.
#'
#' Reports direct `outbound` (concepts it links to), direct `inbound` (concepts
#' linking to it, i.e. backlinks), and `transitive` -- every concept that can
#' reach it by following resolved links (what a change here could ripple to).
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param path Bundle-relative concept path.
#' @return A list with `path`, `outbound`, `inbound`, `transitive` (all sorted
#'   character vectors).
#' @export
okf_impact <- function(con, path) {
  out <- DBI::dbGetQuery(con, "SELECT DISTINCT dst_path FROM okf_link WHERE resolved AND src_path = ? ORDER BY dst_path",
                         params = list(path))$dst_path
  inb <- okf_backlinks(con, path)
  # reverse-reachability: BFS over inbound edges (who depends on this, transitively)
  rev <- DBI::dbGetQuery(con, "SELECT src_path, dst_path FROM okf_link WHERE resolved")
  radj <- list()
  if (nrow(rev)) for (i in seq_len(nrow(rev)))
    radj[[rev$dst_path[i]]] <- c(radj[[rev$dst_path[i]]], rev$src_path[i])
  seen <- character(0); frontier <- path
  while (length(frontier)) {
    nb <- setdiff(unique(unlist(radj[frontier])), c(seen, path))
    seen <- c(seen, nb); frontier <- nb
  }
  list(path = path, outbound = out, inbound = inb, transitive = sort(unique(seen)))
}

#' Deterministic community labels via synchronous label propagation.
#'
#' Operates on the undirected resolved-link graph. Each node starts in its own
#' community; nodes iteratively adopt the most common label among neighbours,
#' ties broken by the lexicographically smallest label (so the result is fully
#' reproducible -- no randomness). Isolated nodes keep their own label.
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param max_iter Maximum propagation sweeps.
#' @param include_reserved Include reserved concepts (`index.md`/`log.md`) as
#'   nodes -- useful for graph visualization, where `index.md` is the hub.
#' @return A data.frame with `path` and integer `cluster` (1-based, stable order).
#' @export
okf_clusters <- function(con, max_iter = 50L, include_reserved = FALSE) {
  g <- .okf_adj(con)
  nodes <- if (include_reserved) g$cps$path else g$cps$path[!as.logical(g$cps$reserved)]
  if (!length(nodes)) return(data.frame(path = character(), cluster = integer()))
  adj <- lapply(g$adj[nodes], function(v) intersect(v, nodes))
  label <- setNames(nodes, nodes)
  for (it in seq_len(max_iter)) {
    changed <- FALSE
    for (n in nodes) {                                # sorted order -> deterministic
      nb <- adj[[n]]
      if (!length(nb)) next
      tab <- sort(table(label[nb]), decreasing = TRUE)
      top <- names(tab)[tab == max(tab)]
      new <- sort(top)[1]                             # tie -> smallest label
      if (!identical(new, label[[n]])) { label[[n]] <- new; changed <- TRUE }
    }
    if (!changed) break
  }
  # renumber labels to compact 1-based ids in order of first appearance
  uniq <- unique(label[nodes]); ids <- setNames(seq_along(uniq), uniq)
  data.frame(path = nodes, cluster = as.integer(ids[label[nodes]]), stringsAsFactors = FALSE)
}

# Assemble the node/edge model used by both the JSON export and the graph page.
# Reserved concepts (index.md hub, log.md) are included as nodes by default --
# index.md is the most-connected node and anchors the visualization.
.okf_graph_model <- function(con, include_reserved = TRUE) {
  g <- .okf_adj(con)
  cl <- okf_clusters(con, include_reserved = include_reserved)
  clmap <- setNames(cl$cluster, cl$path)
  keep <- if (include_reserved) g$cps$path else g$cps$path[!as.logical(g$cps$reserved)]
  cps <- g$cps[g$cps$path %in% keep, , drop = FALSE]
  nodes <- lapply(seq_len(nrow(cps)), function(i) {
    tags <- tryCatch(jsonlite::fromJSON(cps$tags[i]), error = function(e) NULL)
    list(id = cps$path[i],
         type = if (is.na(cps$type[i])) "" else cps$type[i],
         title = if (is.na(cps$title[i])) cps$path[i] else cps$title[i],
         tags = if (length(tags)) as.character(tags) else character(0),
         cluster = unname(clmap[cps$path[i]]) %||% 0L,
         href = sub("\\.md$", ".html", cps$path[i]))
  })
  lks <- DBI::dbGetQuery(con, "SELECT src_path, dst_path, resolved FROM okf_link WHERE resolved")
  lks <- lks[lks$src_path %in% keep & lks$dst_path %in% keep, , drop = FALSE]
  edges <- lapply(seq_len(nrow(lks)), function(i)
    list(source = lks$src_path[i], target = lks$dst_path[i]))
  list(nodes = nodes, edges = edges)
}

#' Export the concept graph as portable JSON (nodes and edges).
#'
#' Returns a JSON object with `nodes` and `edges`. Nodes carry `id` (path),
#' `type`, `title`, `tags`, `cluster` (from [okf_clusters()]), and `href` (the
#' rendered `.html` path). Edges are resolved links with `source` and `target`
#' fields. Feeds any external graph visualizer -- the same
#' "core is a contract" idea as the DuckDB catalog.
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param pretty Pretty-print the JSON.
#' @return A JSON string (invisibly also suitable for writing to a file).
#' @export
okf_graph_json <- function(con, pretty = TRUE) {
  m <- .okf_graph_model(con)
  as.character(jsonlite::toJSON(m, auto_unbox = TRUE, pretty = pretty))
}

#' Render the concept graph as a Mermaid `graph LR` diagram.
#'
#' A text diagram for embedding directly in markdown (READMEs, docs, GitHub
#' renders it natively) -- the lightweight complement to the interactive
#' [okf_graph_html()]. Node ids are sanitized; labels are the concept titles.
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @return A Mermaid diagram as a single string (a ```` ```mermaid ```` block).
#' @export
okf_graph_mermaid <- function(con) {
  m <- .okf_graph_model(con)
  ids <- character(0)
  safe <- function(p) paste0("n", gsub("[^A-Za-z0-9]", "_", p))
  lab  <- function(s) gsub('"', "'", s, fixed = TRUE)
  lines <- c("```mermaid", "graph LR")
  for (n in m$nodes) lines <- c(lines, sprintf('  %s["%s"]', safe(n$id), lab(n$title)))
  for (e in m$edges) lines <- c(lines, sprintf("  %s --> %s", safe(e$source), safe(e$target)))
  lines <- c(lines, "```")
  paste(lines, collapse = "\n")
}

#' Render the concept graph as one self-contained interactive HTML page.
#'
#' A force-directed graph drawn on a `<canvas>` with hand-rolled vanilla JS (no
#' CDN, no framework) -- pan, zoom, drag, type-to-search, nodes coloured by
#' community ([okf_clusters()]). Clicking a node navigates to its rendered
#' `.html` (relative), so dropping `graph.html` into an [okf_html()] site root
#' makes the graph a live map of the site. Fully offline; embeds the node/edge
#' model as JSON.
#'
#' @param con An open DuckDB connection to an okf catalog.
#' @param out Output `.html` file path.
#' @param site_title Optional page title; defaults to the bundle directory name.
#' @return The output path (invisibly).
#' @export
okf_graph_html <- function(con, out, site_title = NULL) {
  m <- .okf_graph_model(con)
  root <- tryCatch(DBI::dbGetQuery(con, "SELECT root FROM okf_bundle LIMIT 1")$root,
                   error = function(e) NA_character_)
  if (is.null(site_title) || is.na(site_title %|NA|% NA))
    site_title <- basename(root %|NA|% "OKF graph")
  data_json <- jsonlite::toJSON(m, auto_unbox = TRUE)
  html <- gsub("__TITLE__", .okf_esc(site_title), OKF_GRAPH_TEMPLATE, fixed = TRUE)
  html <- sub("__DATA__", data_json, html, fixed = TRUE)
  dir.create(dirname(normalizePath(out, mustWork = FALSE)), showWarnings = FALSE, recursive = TRUE)
  writeLines(html, out, useBytes = TRUE)
  cat(sprintf("[okf_graph_html] wrote %s (%d nodes, %d edges)\n",
              out, length(m$nodes), length(m$edges)))
  invisible(out)
}

# Self-contained page: inline CSS + a compact O(n^2) force simulation on canvas.
# Mirrored in py/okf/graph.py (GRAPH_TEMPLATE). __TITLE__ / __DATA__ are filled.
OKF_GRAPH_TEMPLATE <- '<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__ \u2014 graph</title>
<style>
:root{--fg:#1f2328;--mut:#656d76;--line:#d0d7de;--bg:#fff}
html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);
font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;overflow:hidden}
#bar{position:fixed;top:0;left:0;right:0;height:44px;display:flex;gap:.6rem;align-items:center;
padding:0 .9rem;border-bottom:1px solid var(--line);background:rgba(255,255,255,.92);z-index:5}
#bar strong{font-size:.95rem}#bar .mut{color:var(--mut);font-size:.8rem;white-space:nowrap}
#leg{flex:1;overflow:hidden;white-space:nowrap;font-size:.72rem;color:var(--mut)}
#leg span{margin-left:.5rem;margin-right:.15rem}
#q{padding:.3rem .6rem;border:1px solid var(--line);border-radius:6px;font:inherit;width:220px;flex:none}
canvas{display:block;position:absolute;top:44px;left:0}
#tip{position:fixed;pointer-events:none;background:#1f2328;color:#fff;padding:.25rem .5rem;border-radius:6px;
font-size:.8rem;opacity:0;transition:opacity .1s;max-width:340px;z-index:6}
</style></head><body>
<div id="bar"><strong>__TITLE__</strong><span class="mut" id="cnt"></span>
<span id="leg"></span>
<input id="q" placeholder="search title / tag / path\u2026" autocomplete="off"></div>
<canvas id="c"></canvas><div id="tip"></div>
<script>
const G=__DATA__;
const PAL=["#0969da","#1a7f37","#9a6700","#cf222e","#8250df","#bf3989","#0550ae","#116329","#953800","#a40e26","#6639ba","#99286e"];
const cv=document.getElementById("c"),cx=cv.getContext("2d"),tip=document.getElementById("tip"),q=document.getElementById("q");
document.getElementById("cnt").textContent=G.nodes.length+" nodes \u00b7 "+G.edges.length+" links";
let W,H;function size(){W=cv.width=innerWidth;H=cv.height=innerHeight-44;}size();addEventListener("resize",size);
const idx={};G.nodes.forEach((n,i)=>{idx[n.id]=i;n.x=Math.cos(i)*200+W/2;n.y=Math.sin(i*1.7)*200+H/2;n.vx=0;n.vy=0;n.deg=0;});
// colour by OKF type (semantic, varied); fall back to community cluster
const keyset=[...new Set(G.nodes.map(n=>n.type||("c"+(n.cluster||0))))].sort();
const colOf={};keyset.forEach((k,i)=>colOf[k]=PAL[i%PAL.length]);
G.nodes.forEach(n=>n._col=colOf[n.type||("c"+(n.cluster||0))]);
document.getElementById("leg").innerHTML=keyset.map(k=>`<span style="color:${colOf[k]}">\u25cf</span>${k}`).join(" ");
const E=G.edges.filter(e=>idx[e.source]!=null&&idx[e.target]!=null).map(e=>({s:idx[e.source],t:idx[e.target]}));
E.forEach(e=>{G.nodes[e.s].deg++;G.nodes[e.t].deg++;});
let view={x:0,y:0,k:1},hot=null,drag=null,match=null;
function tick(){const N=G.nodes;
 for(let i=0;i<N.length;i++)for(let j=i+1;j<N.length;j++){let dx=N[j].x-N[i].x,dy=N[j].y-N[i].y,d2=dx*dx+dy*dy+0.01,f=6500/d2,d=Math.sqrt(d2);dx/=d;dy/=d;N[i].vx-=dx*f;N[i].vy-=dy*f;N[j].vx+=dx*f;N[j].vy+=dy*f;}
 E.forEach(e=>{let a=N[e.s],b=N[e.t],dx=b.x-a.x,dy=b.y-a.y,d=Math.sqrt(dx*dx+dy*dy)||1,f=(d-110)*0.015;dx/=d;dy/=d;a.vx+=dx*f;a.vy+=dy*f;b.vx-=dx*f;b.vy-=dy*f;});
 N.forEach(n=>{n.vx+=(W/2-n.x)*0.0006;n.vy+=(H/2-n.y)*0.0006;n.x+=n.vx*=0.86;n.y+=n.vy*=0.86;});}
for(let i=0;i<350;i++)tick();   // pre-settle so the initial view is laid out
function draw(){cx.setTransform(1,0,0,1,0,0);cx.clearRect(0,0,W,H);cx.translate(view.x,view.y);cx.scale(view.k,view.k);
 cx.lineWidth=1/view.k;cx.strokeStyle="#d0d7de";E.forEach(e=>{let a=G.nodes[e.s],b=G.nodes[e.t];
  cx.globalAlpha=(match&&!(a._m&&b._m))?0.06:0.5;cx.beginPath();cx.moveTo(a.x,a.y);cx.lineTo(b.x,b.y);cx.stroke();});
 cx.globalAlpha=1;G.nodes.forEach(n=>{let r=4+Math.min(n.deg,10);
  cx.globalAlpha=(match&&!n._m)?0.12:1;cx.beginPath();cx.arc(n.x,n.y,r,0,7);cx.fillStyle=n._col;cx.fill();
  if(n===hot){cx.lineWidth=2/view.k;cx.strokeStyle="#1f2328";cx.stroke();}
  if(view.k>1.4||n.deg>=12||G.nodes.length<=40||n._m||n===hot){cx.fillStyle="#1f2328";cx.font=(11/view.k)+"px sans-serif";cx.fillText(n.title,n.x+r+2,n.y+3);}});cx.globalAlpha=1;}
function loop(){tick();draw();requestAnimationFrame(loop);}loop();
// world<-screen helpers (canvas sits 44px below the top bar)
function wx(cxp){return (cxp-view.x)/view.k;}function wy(cyp){return (cyp-44-view.y)/view.k;}
function at(cxp,cyp){let x=wx(cxp),y=wy(cyp),best=null,bd=400;
 G.nodes.forEach(n=>{let dx=n.x-x,dy=n.y-y,d=dx*dx+dy*dy;if(d<bd){bd=d;best=n;}});return best;}
let moved=false,pan=null;
cv.addEventListener("mousedown",ev=>{moved=false;let n=at(ev.clientX,ev.clientY);
 if(n){drag=n;}else{pan={x:ev.clientX-view.x,y:ev.clientY-view.y};}});
addEventListener("mousemove",ev=>{
 if(drag){drag.x=wx(ev.clientX);drag.y=wy(ev.clientY);drag.vx=drag.vy=0;moved=true;return;}
 if(pan){view.x=ev.clientX-pan.x;view.y=ev.clientY-pan.y;moved=true;return;}
 hot=at(ev.clientX,ev.clientY);
 if(hot){tip.style.opacity=1;tip.style.left=(ev.clientX+12)+"px";tip.style.top=(ev.clientY+12)+"px";
  tip.textContent=hot.title+(hot.type?" ["+hot.type+"]":"")+" \u00b7 "+hot.id;}else tip.style.opacity=0;});
addEventListener("mouseup",ev=>{
 if(drag&&!moved&&drag.href)location.href=drag.href;
 drag=null;pan=null;});
cv.addEventListener("wheel",ev=>{ev.preventDefault();let s=Math.exp(-ev.deltaY*0.0012),mx=ev.clientX,my=ev.clientY-44;
 view.x=mx-(mx-view.x)*s;view.y=my-(my-view.y)*s;view.k*=s;},{passive:false});
q.addEventListener("input",()=>{let t=q.value.trim().toLowerCase();match=t?true:null;
 G.nodes.forEach(n=>{n._m=t&&((n.title+" "+n.id+" "+(n.tags||[]).join(" ")).toLowerCase().includes(t));});});
</script></body></html>'
