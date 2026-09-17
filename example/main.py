"""
TencentDB-Agent-Memory — LangGraph Chat Agent
Backend: FastAPI + LangGraph ReAct Agent
Integrates: Memory V2 API (TAM) + MCP Knowledge Server + OpenAI-compatible LLM

Memory architecture:
  - TAM (episodic): conversation recording, L1 memory extraction, hybrid search
"""

import json
import uuid
import hashlib
from contextvars import ContextVar
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI
from langgraph.checkpoint.memory import MemorySaver
from langgraph.prebuilt import create_react_agent

from mcp_client import MCPClient
from memory_client import MemoryClient


# ── Configuration（全部可通过环境变量覆盖）───────────────────────
import os
MEMORY_URL = os.getenv("MEMORY_URL", "http://127.0.0.1:8420")
MCP_URL = os.getenv("MCP_URL", "http://127.0.0.1:8432/mcp")
LLM_BASE_URL = os.getenv("LLM_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1")
LLM_API_KEY = os.getenv("LLM_API_KEY", "sk-noauth")
LLM_MODEL = os.getenv("LLM_MODEL", "qwen3.8-27b")
ADMIN_KEY = os.getenv("MEMORY_ADMIN_KEY", "")
TEAM_ID = os.getenv("MEMORY_TEAM_ID", "team-demo0000001")
AGENT_ID = os.getenv("MEMORY_AGENT_ID", "agt-demo0000001")

# ── Globals ─────────────────────────────────────────────────────
mcp_client: MCPClient | None = None
agent_executor = None
memory_saver = MemorySaver()
mcp_tools_names: list[str] = []

# Per-user MemoryClient cache
_user_clients: dict[str, MemoryClient] = {}
_current_user_id: ContextVar[str] = ContextVar("current_user_id", default="")
_current_agent_id: ContextVar[str] = ContextVar("current_agent_id", default="")
_current_session_id: ContextVar[str] = ContextVar("current_session_id", default="")
_current_team_id: ContextVar[str] = ContextVar("current_team_id", default=TEAM_ID)
_current_sys_prompt: ContextVar[str] = ContextVar("current_sys_prompt", default="")


def make_user_id(name: str) -> str:
    """Convert display name to ASCII-safe user_id."""
    h = hashlib.md5(name.encode("utf-8")).hexdigest()[:12]
    return f"usr-{h}"


def make_agent_id(name: str) -> str:
    """Generate per-user agent_id for isolated Persona/Memories/Scenarios."""
    h = hashlib.md5(name.encode("utf-8")).hexdigest()[:12]
    return f"agt-{h}"


# ── Lifespan ────────────────────────────────────────────────────
def get_user_client(user_id: str, agent_id: str, team_id: str = TEAM_ID) -> MemoryClient:
    """Get or create a MemoryClient for a specific user."""
    key = f"{team_id}:{user_id}:{agent_id}"
    if key not in _user_clients:
        _user_clients[key] = MemoryClient(MEMORY_URL, ADMIN_KEY, team_id=team_id, user_id=user_id, agent_id=agent_id)
    return _user_clients[key]


@asynccontextmanager
async def lifespan(app: FastAPI):
    global mcp_client, agent_executor, mcp_tools_names

    mcp_client = MCPClient(MCP_URL)

    # Init MCP
    await mcp_client.initialize()
    raw_tools = await mcp_client.list_tools()
    print(f"[INIT] MCP tools loaded: {len(raw_tools)}")

    # Wrap MCP tools as LangChain tools
    lc_tools = []
    for t in raw_tools:
        name = t["name"]
        desc = t.get("description", name)
        input_schema = t.get("inputSchema", {"type": "object", "properties": {}})

        async def _run(tool_name=name, **kwargs):
            return await mcp_client.call_tool(tool_name, kwargs)

        lc_tools.append(_make_tool(name, desc, input_schema, _run))

    # Wrap Memory API as LangChain tools (will use per-request user_id)
    lc_tools.extend(_make_memory_tools())
    mcp_tools_names = [t["name"] for t in raw_tools]

    # Build agent
    llm = ChatOpenAI(model=LLM_MODEL, base_url=LLM_BASE_URL, api_key=LLM_API_KEY, temperature=0.7)

    def _agent_prompt(state):
        # Prepend the per-request system prompt transiently (not persisted in
        # checkpoint): strict vLLM chat templates reject mid-history system
        # messages, and persona/skills should refresh each turn.
        msgs = [m for m in state["messages"] if not isinstance(m, SystemMessage)]
        sys_content = _current_sys_prompt.get()
        if sys_content:
            return [SystemMessage(content=sys_content)] + msgs
        return msgs

    agent_executor = create_react_agent(llm, lc_tools, checkpointer=memory_saver, prompt=_agent_prompt)

    print(f"[INIT] Agent ready. MCP tools: {mcp_tools_names}")
    print(f"[INIT] Memory tools: memory_search, conversation_search, user_persona, list_scenarios")
    yield

    await mcp_client.close()
    for c in _user_clients.values():
        await c.close()


# ── Tool Factory ────────────────────────────────────────────────
def _make_tool(name: str, description: str, schema: dict, coro_fn):
    """Create a LangChain StructuredTool from MCP tool definition."""
    from langchain_core.tools import StructuredTool

    props = schema.get("properties", {})
    required = schema.get("required", [])

    async def _impl(**kwargs):
        return await coro_fn(**kwargs)

    return StructuredTool.from_function(
        coroutine=_impl,
        name=name,
        description=description,
        args_schema=None,
        return_type=str,
    )


def _make_memory_tools() -> list:
    """Create LangChain tools for the Memory V2 API."""
    from langchain_core.tools import StructuredTool

    async def memory_search(query: str, limit: int = 5) -> str:
        """Search long-term memories (persona, facts, knowledge) by semantic similarity."""
        user_id = _current_user_id.get()
        agent_id = _current_agent_id.get()
        team_id = _current_team_id.get()
        client = get_user_client(user_id, agent_id, team_id)
        items = await client.search_memories(query, limit)
        if not items:
            return "No relevant memories found."
        lines = []
        for m in items:
            lines.append(f"- [{m.get('type', '?')}] {m.get('content', '')}")
            if m.get("background"):
                lines.append(f"  context: {m['background']}")
        return "\n".join(lines)

    async def conversation_search(query: str, limit: int = 5) -> str:
        """Search past conversation history by semantic similarity."""
        user_id = _current_user_id.get()
        agent_id = _current_agent_id.get()
        team_id = _current_team_id.get()
        client = get_user_client(user_id, agent_id, team_id)
        msgs = await client.search_conversations(query, limit, session_id=f"default:{user_id}")
        if not msgs:
            return "No relevant conversation history found."
        lines = []
        for m in msgs:
            lines.append(f"- [{m.get('role', '?')}] {m.get('content', '')}")
        return "\n".join(lines)

    async def user_persona() -> str:
        """Get the user's narrative profile / persona. Call this first to understand who the user is."""
        user_id = _current_user_id.get()
        agent_id = _current_agent_id.get()
        team_id = _current_team_id.get()
        client = get_user_client(user_id, agent_id, team_id)
        p = await client.get_persona()
        return p if p else "(No persona available yet)"

    async def list_scenarios() -> str:
        """List active knowledge scenarios (project context, notes, docs)."""
        user_id = _current_user_id.get()
        agent_id = _current_agent_id.get()
        team_id = _current_team_id.get()
        client = get_user_client(user_id, agent_id, team_id)
        entries = await client.list_scenarios()
        if not entries:
            return "No active scenarios."
        lines = []
        for e in entries:
            lines.append(f"- {e.get('path', '?')}: {e.get('summary', '')}")
        return "\n".join(lines)

    return [
        StructuredTool.from_function(coroutine=memory_search, name="memory_search",
                                     description="Search long-term memories by semantic similarity.",
                                     return_type=str),
        StructuredTool.from_function(coroutine=conversation_search, name="conversation_search",
                                     description="Search past conversation history by semantic similarity.",
                                     return_type=str),
        StructuredTool.from_function(coroutine=user_persona, name="user_persona",
                                     description="Get the user's narrative profile. Call first to know who the user is.",
                                     return_type=str),
        StructuredTool.from_function(coroutine=list_scenarios, name="list_scenarios",
                                     description="List active knowledge scenarios (project docs, notes).",
                                     return_type=str),
    ]


# ── App ─────────────────────────────────────────────────────────
app = FastAPI(title="TencentDB-Agent-Memory Chat", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@app.get("/", response_class=HTMLResponse)
async def index():
    with open("static/index.html", encoding="utf-8") as f:
        return f.read()


@app.get("/api/tools")
async def get_tools():
    all_tools = mcp_tools_names + ["memory_search", "conversation_search", "user_persona", "list_scenarios"]
    return {
        "tools": all_tools,
        "mcp": mcp_tools_names,
        "memory": ["memory_search", "conversation_search", "user_persona", "list_scenarios"],
    }


@app.post("/api/memory")
async def get_memory(request: Request):
    body = await request.json()
    display_name = body.get("user_id", "").strip()
    team_id = (body.get("team_id") or "").strip() or TEAM_ID
    agent_id_override = (body.get("agent_id") or "").strip()
    if not display_name:
        return {"error": "user_id required"}

    user_id = make_user_id(display_name)
    agent_id = agent_id_override or make_agent_id(display_name)

    h = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {ADMIN_KEY}",
        "x-tdai-service-id": "default",
        "x-tdai-team-id": team_id,
        "x-tdai-user-id": user_id,
        "x-tdai-agent-id": agent_id,
    }

    persona = ""
    memories = []
    conversations = []
    scenarios = []

    async with httpx.AsyncClient(timeout=30) as http:
        # Persona via v3/core/read (per-user agent_id for isolation)
        try:
            r1 = await http.post(f"{MEMORY_URL}/v3/core/read", headers=h, json={
                "team_id": team_id, "agent_id": agent_id, "user_id": user_id, "session_id": "default",
            })
            persona = r1.json().get("data", {}).get("content", "") or ""
        except Exception:
            pass

        # Memories via v2/atomic/search
        try:
            r2 = await http.post(f"{MEMORY_URL}/v2/atomic/search", headers=h, json={
                "query": "记忆", "limit": 50,
            })
            all_memories = r2.json().get("data", {}).get("items", [])
            memories = [m for m in all_memories if m.get("user_id") == user_id or m.get("userId") == user_id]
        except Exception:
            pass

        # Conversations via v2/conversation/search with per-user sessionId
        try:
            r3 = await http.post(f"{MEMORY_URL}/v2/conversation/search", headers=h, json={
                "query": "对话", "limit": 100, "sessionId": f"default:{user_id}",
            })
            all_convs = r3.json().get("data", {}).get("messages", [])
            conversations = all_convs
        except Exception:
            pass

        # Scenarios via v3/scenario/ls (per-user agent_id)
        try:
            r4 = await http.post(f"{MEMORY_URL}/v3/scenario/ls", headers=h, json={
                "team_id": team_id, "agent_id": agent_id, "user_id": user_id, "session_id": "default",
            })
            scenarios = r4.json().get("data", {}).get("entries", [])
        except Exception:
            pass

    return {
        "user_id": user_id,
        "agent_id": agent_id,
        "team_id": team_id,
        "persona": persona,
        "memories": memories,
        "conversations": conversations,
        "scenarios": scenarios,
    }


@app.post("/api/memory/update")
async def update_memory(request: Request):
    body = await request.json()
    display_name = body.get("user_id", "").strip()
    mem_type = body.get("type", "").strip()
    team_id = (body.get("team_id") or "").strip() or TEAM_ID
    agent_id_override = (body.get("agent_id") or "").strip()

    if not display_name or not mem_type:
        return {"error": "user_id and type required"}

    user_id = make_user_id(display_name)
    agent_id = agent_id_override or make_agent_id(display_name)

    h = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {ADMIN_KEY}",
        "x-tdai-service-id": "default",
        "x-tdai-team-id": team_id,
        "x-tdai-user-id": user_id,
        "x-tdai-agent-id": agent_id,
    }

    async with httpx.AsyncClient(timeout=30) as http:
        if mem_type == "persona":
            content = body.get("content", "")
            r = await http.post(f"{MEMORY_URL}/v3/core/write", headers=h, json={
                "team_id": team_id, "agent_id": agent_id, "user_id": user_id,
                "session_id": "default", "content": content,
            })
            return {"ok": True, "data": r.json().get("data", {})}

        elif mem_type == "memory":
            atomic_id = body.get("id", "")
            content = body.get("content", "")
            background = body.get("background", "")
            update_fields = {}
            if content:
                update_fields["content"] = content
            if background:
                update_fields["background"] = background
            r = await http.post(f"{MEMORY_URL}/v2/atomic/update", headers=h, json={
                "id": atomic_id, "updates": update_fields,
            })
            return {"ok": True, "data": r.json().get("data", {})}

        elif mem_type == "scenario":
            path = body.get("path", "")
            content = body.get("content", "")
            summary = body.get("summary", "")
            r = await http.post(f"{MEMORY_URL}/v2/scenario/write", headers=h, json={
                "file_path": path, "content": content, "summary": summary,
            })
            return {"ok": True, "data": r.json().get("data", {})}

        else:
            return {"error": f"Unknown type: {mem_type}"}


@app.post("/api/memory/delete")
async def delete_memory(request: Request):
    body = await request.json()
    display_name = body.get("user_id", "").strip()
    mem_type = body.get("type", "").strip()
    item_id = body.get("id", "")
    team_id = (body.get("team_id") or "").strip() or TEAM_ID
    agent_id_override = (body.get("agent_id") or "").strip()

    if not display_name or not mem_type:
        return {"error": "user_id and type required"}

    user_id = make_user_id(display_name)
    agent_id = agent_id_override or make_agent_id(display_name)

    h = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {ADMIN_KEY}",
        "x-tdai-service-id": "default",
        "x-tdai-team-id": team_id,
        "x-tdai-user-id": user_id,
        "x-tdai-agent-id": agent_id,
    }

    async with httpx.AsyncClient(timeout=30) as http:
        if mem_type == "memory":
            r = await http.post(f"{MEMORY_URL}/v2/atomic/delete", headers=h, json={
                "atomic_ids": [item_id],
            })
            return {"ok": True, "data": r.json().get("data", {})}
        else:
            return {"error": f"Delete not supported for type: {mem_type}"}


@app.post("/api/memory/scenario")
async def get_scenario_content(request: Request):
    body = await request.json()
    display_name = body.get("user_id", "").strip()
    path = body.get("path", "").strip()
    team_id = (body.get("team_id") or "").strip() or TEAM_ID
    agent_id_override = (body.get("agent_id") or "").strip()

    if not display_name or not path:
        return {"error": "user_id and path required"}

    user_id = make_user_id(display_name)
    agent_id = agent_id_override or make_agent_id(display_name)

    h = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {ADMIN_KEY}",
        "x-tdai-service-id": "default",
        "x-tdai-team-id": team_id,
        "x-tdai-user-id": user_id,
        "x-tdai-agent-id": agent_id,
    }

    async with httpx.AsyncClient(timeout=30) as http:
        r = await http.post(f"{MEMORY_URL}/v2/scenario/read", headers=h, json={
            "file_path": path,
        })
        data = r.json().get("data", {})
        return {"ok": True, "content": data.get("content", ""), "summary": data.get("summary", "")}


@app.post("/api/chat")
async def chat(request: Request):
    body = await request.json()
    user_msg = body.get("message", "").strip()
    thread_id = body.get("thread_id") or str(uuid.uuid4())
    display_name = body.get("user_id", "").strip()
    team_id = (body.get("team_id") or "").strip() or TEAM_ID
    agent_id_override = (body.get("agent_id") or "").strip()

    if not user_msg:
        return {"error": "empty message"}
    if not display_name:
        return {"error": "user_id required"}

    user_id = make_user_id(display_name)
    agent_id = agent_id_override or make_agent_id(display_name)
    session_id = f"{user_id}:{thread_id}"

    # Set context for memory tools
    _current_user_id.set(user_id)
    _current_agent_id.set(agent_id)
    _current_session_id.set(session_id)
    _current_team_id.set(team_id)

    config = {"configurable": {"thread_id": f"{user_id}:{thread_id}"}}

    # Load user's persona (per-user agent_id for isolation)
    client = get_user_client(user_id, agent_id, team_id)
    system_persona = await client.get_persona()

    # Build system prompt with persona
    sys_content = "你是 TencentDB-Agent-Memory 系统中的智能AI助手。"
    if system_persona:
        sys_content += f"\n\n## 用户画像\n{system_persona[:2000]}"
    sys_content += "\n\n你可以使用工具搜索用户记忆、对话历史、知识库。请根据上下文回答，回答要简洁专业。"

    _current_sys_prompt.set(sys_content)
    messages = [HumanMessage(content=user_msg)]

    # Run agent and collect steps
    steps = []
    final_answer = ""

    try:
        async for event in agent_executor.astream({"messages": messages}, config, stream_mode="updates"):
            for node_name, node_output in event.items():
                if node_name == "agent":
                    msgs = node_output.get("messages", [])
                    for m in msgs:
                        if isinstance(m, AIMessage) and m.content:
                            # Check if this is a final answer (no tool calls)
                            if not m.tool_calls:
                                final_answer = m.content
                            else:
                                for tc in m.tool_calls:
                                    steps.append({"tool": tc["name"], "args": tc["args"]})
                elif node_name == "tools":
                    tool_msgs = node_output.get("messages", [])
                    for tm in tool_msgs:
                        content = tm.content or ""
                        steps.append({
                            "tool": getattr(tm, "name", "?"),
                            "result": content[:300],
                        })
    except Exception as e:
        final_answer = f"Agent error: {e}"
        print(f"[ERROR] {e}")

    # ── Post-response: TAM sediment (episodic L0) ──
    conv_messages = [
        {"role": "user", "content": user_msg},
        {"role": "assistant", "content": final_answer},
    ]

    if final_answer:
        try:
            await client.add_conversation(f"default:{user_id}", conv_messages)
        except Exception:
            pass

    return {
        "response": final_answer,
        "thread_id": thread_id,
        "agent_id": agent_id,
        "team_id": team_id,
        "steps": steps,
    }


@app.get("/api/health")
async def health():
    return {
        "status": "ok",
        "mcp": MCP_URL,
        "memory": MEMORY_URL,
        "llm": LLM_MODEL,
    }


# ── Entry ───────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8501, reload=False)
