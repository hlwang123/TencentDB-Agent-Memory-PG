"""MCP HTTP Client — communicates with the knowledge-mcp server via Streamable HTTP."""

import httpx


class MCPClient:
    def __init__(self, url: str):
        self.url = url
        self._id = 0
        self._session: httpx.AsyncClient | None = None

    async def _get_session(self) -> httpx.AsyncClient:
        if self._session is None or self._session.is_closed:
            self._session = httpx.AsyncClient(timeout=60)
        return self._session

    async def _request(self, method: str, params: dict | None = None) -> dict | None:
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            payload["params"] = params

        session = await self._get_session()
        resp = await session.post(
            self.url,
            json=payload,
            headers={"Content-Type": "application/json",
                     "Accept": "application/json, text/event-stream"},
        )
        text = resp.text

        # Try direct JSON
        try:
            obj = __import__("json").loads(text)
            if "result" in obj:
                return obj["result"]
        except Exception:
            pass

        # Parse SSE
        for line in text.split("\n"):
            if line.startswith("data: "):
                try:
                    obj = __import__("json").loads(line[6:])
                    if "result" in obj:
                        return obj["result"]
                except Exception:
                    pass
        return None

    async def initialize(self) -> dict | None:
        return await self._request("initialize", {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "langgraph-agent", "version": "1.0.0"},
        })

    async def list_tools(self) -> list[dict]:
        result = await self._request("tools/list")
        return result.get("tools", []) if result else []

    async def call_tool(self, name: str, arguments: dict) -> str:
        result = await self._request("tools/call", {"name": name, "arguments": arguments})
        if not result:
            return '{"error": "no response from MCP"}'
        content = result.get("content", [])
        if content and isinstance(content, list):
            return content[0].get("text", str(result))
        return str(result)

    async def close(self):
        if self._session and not self._session.is_closed:
            await self._session.aclose()
