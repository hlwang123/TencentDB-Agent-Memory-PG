"""Memory V2 API Client — interfaces with TencentDB-Agent-Memory core."""

import httpx


class MemoryClient:
    def __init__(self, base_url: str, api_key: str, team_id: str = "", user_id: str = "", agent_id: str = ""):
        self.base_url = base_url.rstrip("/")
        self.headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            "x-tdai-service-id": "default",
        }
        if team_id:
            self.headers["x-tdai-team-id"] = team_id
        if user_id:
            self.headers["x-tdai-user-id"] = user_id
        if agent_id:
            self.headers["x-tdai-agent-id"] = agent_id
        self._session: httpx.AsyncClient | None = None

    async def _get_session(self) -> httpx.AsyncClient:
        if self._session is None or self._session.is_closed:
            self._session = httpx.AsyncClient(timeout=30)
        return self._session

    async def _call(self, path: str, body: dict | None = None) -> dict:
        session = await self._get_session()
        resp = await session.post(
            f"{self.base_url}{path}",
            json=body or {},
            headers=self.headers,
        )
        return resp.json()

    async def get_persona(self) -> str:
        try:
            res = await self._call("/v2/core/read")
            return res.get("data", {}).get("content", "")
        except Exception:
            return ""

    async def search_memories(self, query: str, limit: int = 5) -> list[dict]:
        try:
            res = await self._call("/v2/atomic/search", {"query": query, "limit": limit})
            return res.get("data", {}).get("items", [])
        except Exception:
            return []

    async def search_conversations(self, query: str, limit: int = 5, session_id: str = "") -> list[dict]:
        try:
            body: dict = {"query": query, "limit": limit}
            if session_id:
                body["sessionId"] = session_id
            res = await self._call("/v2/conversation/search", body)
            return res.get("data", {}).get("messages", [])
        except Exception:
            return []

    async def list_scenarios(self) -> list[dict]:
        try:
            res = await self._call("/v2/scenario/ls")
            return res.get("data", {}).get("entries", [])
        except Exception:
            return []

    async def add_conversation(self, session_id: str, messages: list[dict]) -> dict:
        try:
            res = await self._call("/v2/conversation/add", {
                "sessionId": session_id,
                "messages": messages,
            })
            return res.get("data", {})
        except Exception:
            return {}

    async def close(self):
        if self._session and not self._session.is_closed:
            await self._session.aclose()
