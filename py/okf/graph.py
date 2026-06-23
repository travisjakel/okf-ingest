"""okf graph affordances (Python) — mirrors r/okf/R/okf_graph.R.

All DETERMINISTIC; no LLM. The catalog already holds the concept graph
(okf_link); these surface it for navigation and visualization:
    backlinks(con, path)   -> who links TO a concept ("linked from")
    impact(con, path)      -> inbound / outbound / transitive ripple
    clusters(con)          -> community label per concept (label propagation)
    graph_json(con)        -> portable {nodes, edges} for any visualizer
    graph_html(con, out)   -> one self-contained force-directed page (no CDN)
"""
from __future__ import annotations
import json, os, re
from typing import Optional


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _adj(con):
    """Undirected adjacency over resolved links + the full concept rows."""
    cps = con.execute(
        "SELECT path, reserved, type, title, tags FROM okf_concept ORDER BY path").fetchall()
    adj = {r[0]: set() for r in cps}
    for s, d in con.execute("SELECT src_path, dst_path FROM okf_link WHERE resolved").fetchall():
        adj.setdefault(s, set()).add(d)
        adj.setdefault(d, set()).add(s)
    return cps, adj


def backlinks(con, path: str) -> list:
    """Concepts that link to `path` (resolved inbound links), sorted."""
    return [r[0] for r in con.execute(
        "SELECT DISTINCT src_path FROM okf_link WHERE resolved AND dst_path = ? ORDER BY src_path",
        [path]).fetchall()]


def impact(con, path: str) -> dict:
    """Direct `outbound`, direct `inbound` (backlinks), and `transitive` — every
    concept that can reach `path` by following resolved links (the ripple)."""
    out = [r[0] for r in con.execute(
        "SELECT DISTINCT dst_path FROM okf_link WHERE resolved AND src_path = ? ORDER BY dst_path",
        [path]).fetchall()]
    inb = backlinks(con, path)
    radj = {}
    for s, d in con.execute("SELECT src_path, dst_path FROM okf_link WHERE resolved").fetchall():
        radj.setdefault(d, []).append(s)
    seen, frontier = set(), [path]
    while frontier:
        nxt = []
        for p in frontier:
            for s in radj.get(p, ()):
                if s not in seen and s != path:
                    seen.add(s); nxt.append(s)
        frontier = nxt
    return {"path": path, "outbound": out, "inbound": inb, "transitive": sorted(seen)}


def clusters(con, max_iter: int = 50, include_reserved: bool = False) -> list:
    """Deterministic community labels via synchronous label propagation on the
    undirected resolved-link graph. Nodes adopt the most common neighbour label,
    ties broken by the smallest label (fully reproducible). Returns a list of
    {path, cluster} (1-based ids, stable order)."""
    cps, adj = _adj(con)
    nodes = [r[0] for r in cps] if include_reserved else [r[0] for r in cps if not r[1]]
    if not nodes:
        return []
    nodeset = set(nodes)
    nadj = {n: [x for x in adj.get(n, ()) if x in nodeset] for n in nodes}
    label = {n: n for n in nodes}
    for _ in range(max_iter):
        changed = False
        for n in nodes:                       # sorted order -> deterministic
            nb = nadj[n]
            if not nb:
                continue
            counts = {}
            for x in nb:
                counts[label[x]] = counts.get(label[x], 0) + 1
            mx = max(counts.values())
            new = sorted(k for k, v in counts.items() if v == mx)[0]
            if new != label[n]:
                label[n] = new; changed = True
        if not changed:
            break
    ids, out = {}, []
    for n in nodes:
        lab = label[n]
        if lab not in ids:
            ids[lab] = len(ids) + 1
        out.append({"path": n, "cluster": ids[lab]})
    return out


def _graph_model(con, include_reserved: bool = True) -> dict:
    """Node/edge model shared by the JSON export and the graph page. Reserved
    concepts (index.md hub, log.md) are nodes by default — index.md anchors the
    layout."""
    cps, _ = _adj(con)
    clmap = {c["path"]: c["cluster"] for c in clusters(con, include_reserved=include_reserved)}
    keep = set(r[0] for r in cps) if include_reserved else set(r[0] for r in cps if not r[1])
    nodes = []
    for path, reserved, typ, title, tags in cps:
        if path not in keep:
            continue
        try:
            tl = json.loads(tags) if tags else []
        except Exception:
            tl = []
        nodes.append({
            "id": path, "type": typ or "", "title": title or path,
            "tags": [str(t) for t in tl] if tl else [],
            "cluster": clmap.get(path, 0),
            "href": re.sub(r"\.md$", ".html", path)})
    edges = []
    for s, d in con.execute("SELECT src_path, dst_path FROM okf_link WHERE resolved").fetchall():
        if s in keep and d in keep:
            edges.append({"source": s, "target": d})
    return {"nodes": nodes, "edges": edges}


def graph_json(con, pretty: bool = True) -> str:
    """Portable `{nodes, edges}` JSON. Nodes carry id/type/title/tags/cluster/href;
    edges are resolved links {source, target}."""
    return json.dumps(_graph_model(con), indent=2 if pretty else None)


def graph_mermaid(con) -> str:
    """Render the concept graph as a Mermaid `graph LR` diagram (a ```mermaid
    block) for embedding in markdown — the lightweight complement to graph_html.
    Node ids are sanitized; labels are concept titles."""
    m = _graph_model(con)
    safe = lambda p: "n" + re.sub(r"[^A-Za-z0-9]", "_", p)
    lab = lambda s: s.replace('"', "'")
    lines = ["```mermaid", "graph LR"]
    lines += [f'  {safe(n["id"])}["{lab(n["title"])}"]' for n in m["nodes"]]
    lines += [f'  {safe(e["source"])} --> {safe(e["target"])}' for e in m["edges"]]
    lines.append("```")
    return "\n".join(lines)


def graph_html(con, out: str, site_title: Optional[str] = None) -> str:
    """Render the concept graph as one self-contained interactive HTML page — a
    force-directed canvas (hand-rolled vanilla JS, no CDN): pan, zoom, drag,
    type-to-search, nodes coloured by OKF type (community fallback). Clicking a
    node navigates to its rendered `.html`. Returns the output path."""
    m = _graph_model(con)
    row = con.execute("SELECT root FROM okf_bundle LIMIT 1").fetchone()
    if not site_title:
        site_title = os.path.basename(row[0]) if row and row[0] else "OKF graph"
    html = GRAPH_TEMPLATE.replace("__TITLE__", _esc(site_title)).replace(
        "__DATA__", json.dumps(m), 1)
    d = os.path.dirname(os.path.abspath(out))
    os.makedirs(d, exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(html)
    print(f"[graph_html] wrote {out} ({len(m['nodes'])} nodes, {len(m['edges'])} edges)")
    return out


# Self-contained page, mirrored verbatim from r/okf/R/okf_graph.R (OKF_GRAPH_TEMPLATE).
GRAPH_TEMPLATE = '''<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__ — graph</title>
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
<input id="q" placeholder="search title / tag / path…" autocomplete="off"></div>
<canvas id="c"></canvas><div id="tip"></div>
<script>
const G=__DATA__;
const PAL=["#0969da","#1a7f37","#9a6700","#cf222e","#8250df","#bf3989","#0550ae","#116329","#953800","#a40e26","#6639ba","#99286e"];
const cv=document.getElementById("c"),cx=cv.getContext("2d"),tip=document.getElementById("tip"),q=document.getElementById("q");
document.getElementById("cnt").textContent=G.nodes.length+" nodes · "+G.edges.length+" links";
let W,H;function size(){W=cv.width=innerWidth;H=cv.height=innerHeight-44;}size();addEventListener("resize",size);
const idx={};G.nodes.forEach((n,i)=>{idx[n.id]=i;n.x=Math.cos(i)*200+W/2;n.y=Math.sin(i*1.7)*200+H/2;n.vx=0;n.vy=0;n.deg=0;});
// colour by OKF type (semantic, varied); fall back to community cluster
const keyset=[...new Set(G.nodes.map(n=>n.type||("c"+(n.cluster||0))))].sort();
const colOf={};keyset.forEach((k,i)=>colOf[k]=PAL[i%PAL.length]);
G.nodes.forEach(n=>n._col=colOf[n.type||("c"+(n.cluster||0))]);
document.getElementById("leg").innerHTML=keyset.map(k=>`<span style="color:${colOf[k]}">●</span>${k}`).join(" ");
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
  if(view.k>1.4||n.deg>=12||n._m||n===hot){cx.fillStyle="#1f2328";cx.font=(11/view.k)+"px sans-serif";cx.fillText(n.title,n.x+r+2,n.y+3);}});cx.globalAlpha=1;}
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
  tip.textContent=hot.title+(hot.type?" ["+hot.type+"]":"")+" · "+hot.id;}else tip.style.opacity=0;});
addEventListener("mouseup",ev=>{
 if(drag&&!moved&&drag.href)location.href=drag.href;
 drag=null;pan=null;});
cv.addEventListener("wheel",ev=>{ev.preventDefault();let s=Math.exp(-ev.deltaY*0.0012),mx=ev.clientX,my=ev.clientY-44;
 view.x=mx-(mx-view.x)*s;view.y=my-(my-view.y)*s;view.k*=s;},{passive:false});
q.addEventListener("input",()=>{let t=q.value.trim().toLowerCase();match=t?true:null;
 G.nodes.forEach(n=>{n._m=t&&((n.title+" "+n.id+" "+(n.tags||[]).join(" ")).toLowerCase().includes(t));});});
</script></body></html>'''
