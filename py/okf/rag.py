"""okf RAG layer (Python) — mirrors the R binding's embeddings/RAG functions.

Pluggable embedder (default: local Ollama nomic-embed-text); brute-force cosine
search via DuckDB's native list_cosine_similarity. An embedder is a callable
texts:list[str] -> list[list[float]].
"""
from __future__ import annotations
import os, re, json, urllib.request
from typing import Callable, Optional


def chunk_body(body: str, target_chars: int = 600) -> list:
    paras = [p.strip() for p in re.split(r"\n[ \t]*\n", body or "") if p.strip()]
    chunks, cur = [], ""
    for p in paras:
        if not cur:
            cur = p
        elif len(cur) + len(p) + 2 <= target_chars:
            cur = f"{cur}\n\n{p}"
        else:
            chunks.append(cur); cur = p
    if cur:
        chunks.append(cur)
    return chunks


def _embed_endpoint(base: Optional[str] = None) -> tuple[str, str]:
    """(url, shape) for the local embedder. shape is 'openai' | 'ollama_batch' |
    'ollama_single'. llama-swap serves the OpenAI shape on :11435 and does NOT
    serve Ollama's /api/embeddings, so the path is resolved, never hard-coded.
    An explicit `base` (the caller's Ollama root) still wins, as before.
    Order: base, then LLM_EMBED_URL, then LLM_LOCAL_BACKEND=llamaswap, then OLLAMA_URL."""
    u = (base.rstrip("/") + "/api/embeddings") if base else os.environ.get("LLM_EMBED_URL", "")
    if not u:
        if os.environ.get("LLM_LOCAL_BACKEND", "ollama").strip().lower() == "llamaswap":
            root = os.environ.get("LLAMASWAP_URL",
                                  "http://127.0.0.1:11435/v1/chat/completions").rstrip("/")
            if root.endswith("/v1/chat/completions"):
                root = root[: -len("/v1/chat/completions")]
            u = root + "/v1/embeddings"
        else:
            u = os.environ.get("OLLAMA_URL", "http://localhost:11434").rstrip("/") + "/api/embeddings"
    p = u.rstrip("/")
    if p.endswith("/v1/embeddings"):
        return u, "openai"
    if p.endswith("/api/embeddings"):
        return u, "ollama_single"
    return u, "ollama_batch"


def ollama_embedder(model: str = "nomic-embed-text",
                    url: Optional[str] = None) -> Callable:
    endpoint, shape = _embed_endpoint(url)

    def embed(texts):
        out = []
        for t in texts:
            body = ({"model": model, "prompt": t} if shape == "ollama_single"
                    else {"model": model, "input": [t]})
            req = urllib.request.Request(
                endpoint,
                data=json.dumps(body).encode("utf-8"),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=120) as r:
                j = json.loads(r.read())
            if shape == "ollama_single":
                out.append(j["embedding"])
            elif shape == "openai":
                out.append(j["data"][0]["embedding"])
            else:
                out.append(j["embeddings"][0])
        return out
    return embed


def _vec_lit(v) -> str:
    return "[" + ",".join(f"{float(z):.8g}" for z in v) + "]::FLOAT[]"


def embed(con, embedder: Optional[Callable] = None, target_chars: int = 600,
          incremental: bool = False) -> int:
    """Chunk + embed concept bodies, storing each concept's content_hash. By
    default replaces all chunks; with incremental=True, re-embeds only concepts
    whose content_hash changed (and drops removed concepts' chunks), skipping the
    expensive embedder calls for unchanged concepts. Returns chunks written."""
    embedder = embedder or ollama_embedder()
    con.execute("CREATE TABLE IF NOT EXISTS okf_chunk (bundle_id TEXT, path TEXT, "
                "chunk_id INTEGER, text TEXT, embedding FLOAT[], content_hash TEXT)")
    rows = con.execute(
        "SELECT bundle_id, path, body, content_hash FROM okf_concept "
        "WHERE reserved = FALSE ORDER BY path").fetchall()
    if incremental:
        have = dict(con.execute("SELECT DISTINCT path, content_hash FROM okf_chunk").fetchall())
        cur_paths = {r[1] for r in rows}
        stale = set(p for p in have if p not in cur_paths) | \
                set(r[1] for r in rows if have.get(r[1]) != r[3])
        if stale:
            con.execute("DELETE FROM okf_chunk WHERE path IN ({})".format(
                ",".join("?" * len(stale))), list(stale))
        rows = [r for r in rows if r[1] in stale or r[1] not in have]
    else:
        con.execute("DELETE FROM okf_chunk")
    n = 0
    for bundle_id, path, body, chash in rows:
        chs = chunk_body(body, target_chars)
        if not chs:
            continue
        embs = embedder(chs)
        for k, (text, vec) in enumerate(zip(chs, embs), start=1):
            con.execute(
                f"INSERT INTO okf_chunk VALUES (?,?,?,?, {_vec_lit(vec)}, ?)",
                [bundle_id, path, k, text, chash])
            n += 1
    return n


def rag(con, query: str, embedder: Optional[Callable] = None, k: int = 5):
    embedder = embedder or ollama_embedder()
    qv = embedder([query])[0]
    return con.execute(
        f"""SELECT ch.path, c.title, ch.chunk_id,
                   list_cosine_similarity(ch.embedding, {_vec_lit(qv)}) AS score, ch.text
            FROM okf_chunk ch JOIN okf_concept c USING (bundle_id, path)
            WHERE ch.embedding IS NOT NULL ORDER BY score DESC LIMIT {int(k)}"""
    ).fetchall()
