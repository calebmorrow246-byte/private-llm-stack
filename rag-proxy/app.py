"""
Minimal OpenAI-compatible RAG proxy for the FreshService KB agent.

Open WebUI's own built-in RAG (both the native tool-calling path and the "legacy"
static-injection path) proved unreliable in this stack - small/quantized models via
Ollama narrate using a search tool as plain text instead of actually invoking it, and
the legacy path never fired despite reaching the right code (see
openwebui-builtin-tools-gotcha memory / LLM plan for the full investigation). This
service does retrieval ourselves, deterministically, with no dependency on a model's
tool-calling behavior:

  1. Embed the last user message via Ollama (nomic-embed-text).
  2. Vector-search Qdrant's existing `open-webui_knowledge` collection, filtered to this
     KB's tenant_id (points already there from Ingest-KbCorpus.ps1 - no separate index).
  3. Prepend the retrieved chunks to the system message as explicit context.
  4. Forward the (now grounded) request to LiteLLM for actual generation, and return its
     response unmodified.

Open WebUI is pointed at this as an ordinary second OpenAI-compatible connection - it
just sees one more selectable model, no per-model Knowledge/capabilities config needed.
"""
import json
import os
import time
import uuid

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

APP_MODEL_ID = os.environ.get("RAG_PROXY_MODEL_ID", "freshservice-kb-rag")
PROXY_API_KEY = os.environ["RAG_PROXY_API_KEY"]
LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://litellm:4000")
LITELLM_API_KEY = os.environ["LITELLM_MASTER_KEY"]
LITELLM_CHAT_MODEL = os.environ.get("LITELLM_CHAT_MODEL", "llama-3.1-8b")
OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
QDRANT_BASE_URL = os.environ.get("QDRANT_BASE_URL", "http://qdrant:6333")
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "open-webui_knowledge")
KB_TENANT_ID = os.environ["KB_TENANT_ID"]

# article_id -> Freshservice folder_visibility (1 = public/everyone; 3, 7 = internal/
# restricted in this org's setup, confirmed 2026-08-26). Built once from the original
# KB export in freshservice-kb-work/archive/kb-standardization-326/backups/*.original.json
# (303/324 articles covered - articles missing from this map are treated as non-public,
# the safe default, since we can't confirm they're safe to hand to an end user).
PUBLIC_VISIBILITY_CODE = 1
with open(os.path.join(os.path.dirname(__file__), "article_visibility.json")) as f:
    ARTICLE_VISIBILITY: dict[str, int] = json.load(f)
TOP_K = int(os.environ.get("RAG_TOP_K", "5"))
# Only ~17% of the corpus is public (55/303 mapped). Over-fetch from Qdrant so a public
# article ranked just outside a plain top-5 isn't missed once non-public hits are
# filtered out below.
SEARCH_LIMIT = int(os.environ.get("RAG_SEARCH_LIMIT", "20"))

app = FastAPI()


def _check_auth(authorization: str | None) -> None:
    if authorization != f"Bearer {PROXY_API_KEY}":
        raise HTTPException(status_code=401, detail="Invalid API key")


@app.get("/v1/models")
async def list_models(authorization: str | None = Header(default=None)) -> JSONResponse:
    _check_auth(authorization)
    return JSONResponse({
        "object": "list",
        "data": [{"id": APP_MODEL_ID, "object": "model", "owned_by": "rag-proxy", "created": 0}],
    })


async def _embed(client: httpx.AsyncClient, text: str) -> list[float]:
    r = await client.post(
        f"{OLLAMA_BASE_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": text},
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["embeddings"][0]


async def _search_kb(client: httpx.AsyncClient, vector: list[float]) -> list[dict]:
    r = await client.post(
        f"{QDRANT_BASE_URL}/collections/{QDRANT_COLLECTION}/points/search",
        json={
            "vector": vector,
            "limit": SEARCH_LIMIT,
            "with_payload": True,
            "filter": {"must": [{"key": "tenant_id", "match": {"value": KB_TENANT_ID}}]},
        },
        timeout=15,
    )
    r.raise_for_status()
    return r.json()["result"]


SYSTEM_INSTRUCTIONS_BASE = """You are the company IT FreshService Knowledge Base assistant, helping an end user.

Rules:
- Answer ONLY using the KB articles provided below. Never invent steps, UI labels, or
  URLs that aren't in the provided text.
- Each article is labeled with its public FreshService KB link. When you use an
  article, cite that exact URL as a plain link (e.g. "See: https://...") - do not
  wrap it in markdown link syntax with an invented title, since no article titles are
  provided to you. Never cite a filename or a made-up "Article 1/2/3" label.
- Never merge steps from multiple conflicting articles into one composite answer.
- If you are told below that there is no public article for this question (whether
  because nothing matched at all, or because the only matches are internal/restricted
  articles not meant for end users), your reply MUST do both of these things, every
  time, no exceptions:
  1. Say plainly that you couldn't find this in the public Knowledge Base.
  2. Explicitly offer to help the user open a FreshService support ticket, and give
     them this link to submit one: https://example.freshservice.com/support/home
     (do not create the ticket yourself, only offer and give the link).
  A bare "I couldn't find an answer" with no ticket offer is NOT an acceptable
  response in this situation."""

# First message in a conversation: ALWAYS ask one round of clarifying questions before
# giving any steps, regardless of whether one retrieved article already looks general
# enough to cover it - the user has explicitly asked for this even in the unambiguous
# case, rather than have the agent silently pick an interpretation.
SYSTEM_INSTRUCTIONS_FIRST_TURN = SYSTEM_INSTRUCTIONS_BASE + """

- This is the FIRST message in this conversation. Do NOT give steps or a final answer
  yet, even if one retrieved article looks like a clear, general match. Instead, ask
  ONE round of clarifying question(s) based on what actually distinguishes the
  retrieved articles (or, if nothing relevant was retrieved, ask what the user is
  trying to do / on what system, to help find the right article). State your
  understanding of the request and ask what's needed to pick the right article -
  do not cite an article or give any steps in this message."""

# Every message after the first: the user has now answered the clarifying question(s)
# from the previous turn - commit to an answer this time, don't ask again.
SYSTEM_INSTRUCTIONS_FOLLOWUP = SYSTEM_INSTRUCTIONS_BASE + """

- The user has already answered a clarifying question in this conversation. Using
  their answer plus the retrieved articles below, commit to the single best-matching
  article now and give its steps - do not ask another clarifying question, do not
  reinterpret or second-guess an answer they already gave, and do not keep narrowing
  further once one article is a reasonable match."""


FRESHSERVICE_ARTICLE_URL = "https://example.freshservice.com/a/solutions/articles/{article_id}"
NO_PUBLIC_ARTICLE_MSG = (
    "No PUBLIC FreshService Knowledge Base article answers this question (either "
    "nothing matched, or the only matches are internal/restricted articles not meant "
    "for end users). Offer to help the user open a support ticket instead, per the "
    "rules above - do not describe or use any internal article content."
)


def _article_id(source_filename: str) -> str:
    # Filenames are "<ticketId>_<folderId>_<articleId>.html" - the article id (the
    # last underscore-separated segment) is what the public KB URL uses, e.g.
    # "1000_2000_3000.html" -> .../articles/3000.
    return source_filename.removesuffix(".html").rsplit("_", 1)[-1]


def _article_url(article_id: str) -> str:
    return FRESHSERVICE_ARTICLE_URL.format(article_id=article_id)


def _is_public(article_id: str) -> bool:
    return ARTICLE_VISIBILITY.get(article_id) == PUBLIC_VISIBILITY_CODE


def _build_context_block(hits: list[dict], is_first_turn: bool) -> str:
    system_instructions = SYSTEM_INSTRUCTIONS_FIRST_TURN if is_first_turn else SYSTEM_INSTRUCTIONS_FOLLOWUP
    public_hits = []
    for hit in hits:
        source = hit.get("payload", {}).get("metadata", {}).get("source", "unknown")
        if source != "unknown" and _is_public(_article_id(source)):
            public_hits.append(hit)
    hits = public_hits[:TOP_K]

    if not hits:
        return system_instructions + "\n\n" + NO_PUBLIC_ARTICLE_MSG
    parts = [system_instructions, "\nRetrieved FreshService Knowledge Base articles:"]
    for hit in hits:
        payload = hit.get("payload", {})
        source = payload.get("metadata", {}).get("source", "unknown")
        text = payload.get("text", "")
        url = _article_url(_article_id(source)) if source != "unknown" else "unknown"
        parts.append(f"\n--- Article link: {url} (relevance: {hit.get('score', 0):.2f}) ---\n{text}")
    return "\n".join(parts)


def _build_retrieval_query(messages: list[dict], max_turns: int = 4) -> str | None:
    # Embedding only the latest message loses the original question's topic on a
    # short follow-up reply (e.g. "on my laptop" alone, answering a clarifying
    # question) - concatenate the last few conversation turns instead so the search
    # stays anchored to what's actually being discussed.
    convo_messages = [m for m in messages if m.get("role") in ("user", "assistant")]
    recent = convo_messages[-max_turns:]
    if not recent:
        return None
    return "\n".join(f"{m['role']}: {m['content']}" for m in recent)


async def _retrieve_and_build_messages(client: httpx.AsyncClient, messages: list[dict]) -> list[dict]:
    # Exactly one user message and no assistant reply yet = this is the very first
    # turn of the conversation, before any clarifying question has been asked.
    convo_turns = [m for m in messages if m.get("role") in ("user", "assistant")]
    is_first_turn = len(convo_turns) <= 1

    query_text = _build_retrieval_query(messages)
    if query_text:
        try:
            vector = await _embed(client, query_text)
            hits = await _search_kb(client, vector)
        except httpx.HTTPError as e:
            raise HTTPException(status_code=502, detail=f"Retrieval failed: {e}")
        context_block = _build_context_block(hits, is_first_turn)
    else:
        context_block = "No user question found to search the Knowledge Base for."

    # Inject as a fresh system message ahead of the conversation. Any existing system
    # message from the caller is kept, appended after the retrieved context.
    existing_system = [m["content"] for m in messages if m.get("role") == "system"]
    non_system = [m for m in messages if m.get("role") != "system"]
    injected_system = context_block + ("\n\n" + "\n\n".join(existing_system) if existing_system else "")
    return [{"role": "system", "content": injected_system}] + non_system


@app.post("/v1/chat/completions")
async def chat_completions(request: Request, authorization: str | None = Header(default=None)):
    _check_auth(authorization)
    body = await request.json()
    messages = body.get("messages", [])
    client_wants_stream = bool(body.get("stream"))
    chat_id = f"chatcmpl-rag-{uuid.uuid4()}"

    async with httpx.AsyncClient() as client:
        forwarded_messages = await _retrieve_and_build_messages(client, messages)
        forwarded_body = {**body, "model": LITELLM_CHAT_MODEL, "messages": forwarded_messages}
        # Strip any tools Open WebUI attached to the outgoing request (its own
        # builtin-tools kit, if this model's row doesn't have builtin_tools=false set) -
        # this proxy does its own retrieval, it never wants a model deciding to call a
        # tool instead of just answering. Without this, small models here hallucinate a
        # fake tool-call reply instead of using the injected KB context (see
        # openwebui-builtin-tools-gotcha memory).
        forwarded_body.pop("tools", None)
        forwarded_body.pop("tool_choice", None)

        if not client_wants_stream:
            r = await client.post(
                f"{LITELLM_BASE_URL}/v1/chat/completions",
                headers={"Authorization": f"Bearer {LITELLM_API_KEY}"},
                json={**forwarded_body, "stream": False},
                timeout=120,
            )
            r.raise_for_status()
            upstream = r.json()
            upstream["id"] = chat_id
            upstream["model"] = APP_MODEL_ID
            upstream["created"] = int(time.time())
            return JSONResponse(upstream)

    # Retrieval is fast (sub-second) and already done above; from here on, relay
    # LiteLLM's real token-by-token stream through live rather than buffering the
    # whole answer first - Open WebUI's frontend silently gives up waiting if no SSE
    # bytes arrive within a few seconds of connecting, which a "generate everything
    # first, stream it all at once at the end" approach tripped on the CPU-bound
    # models here (real generation can take 10s of seconds).
    async def _relay():
        async with httpx.AsyncClient() as stream_client:
            async with stream_client.stream(
                "POST",
                f"{LITELLM_BASE_URL}/v1/chat/completions",
                headers={"Authorization": f"Bearer {LITELLM_API_KEY}"},
                json={**forwarded_body, "stream": True},
                timeout=120,
            ) as r:
                r.raise_for_status()
                async for line in r.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    payload = line[len("data: "):]
                    if payload.strip() == "[DONE]":
                        yield "data: [DONE]\n\n"
                        continue
                    try:
                        chunk = json.loads(payload)
                    except json.JSONDecodeError:
                        continue
                    chunk["id"] = chat_id
                    chunk["model"] = APP_MODEL_ID
                    yield f"data: {json.dumps(chunk)}\n\n"

    return StreamingResponse(_relay(), media_type="text/event-stream")
