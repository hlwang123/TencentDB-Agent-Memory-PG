#!/usr/bin/env python3
"""Quick atomic search test.

    MEMORY_URL=http://127.0.0.1:8420 MEMORY_ADMIN_KEY=<admin-key> python test_search.py
"""
import os

import requests
import json

BASE = os.getenv("MEMORY_URL", "http://127.0.0.1:8420")
ADMIN_KEY = os.getenv("MEMORY_ADMIN_KEY", "")
USER_ID = "usr-testpg000001"
AGENT_ID = "agt-testpg000001"
TEAM_ID = os.getenv("MEMORY_TEAM_ID", "team-demo0000001")

headers = {
    "Content-Type": "application/json",
    "Authorization": f"Bearer {ADMIN_KEY}",
    "x-tdai-service-id": "default",
    "x-tdai-team-id": TEAM_ID,
    "x-tdai-user-id": USER_ID,
    "x-tdai-agent-id": AGENT_ID,
}

# Atomic search
print("=== Atomic search ===")
r = requests.post(f"{BASE}/v2/atomic/search", headers=headers, json={
    "query": "PostgreSQL迁移",
    "limit": 5
})
print(f"Status: {r.status_code}")
resp = r.json()
print(f"Response: {json.dumps(resp, ensure_ascii=False, indent=2)[:1000]}")

# Also try conversation search
print("\n=== Conversation search ===")
r = requests.post(f"{BASE}/v2/conversation/search", headers=headers, json={
    "query": "pgvector存储",
    "limit": 3
})
print(f"Status: {r.status_code}")
resp = r.json()
print(f"Messages count: {len(resp.get('data', {}).get('messages', []))}")
for msg in resp.get("data", {}).get("messages", [])[:3]:
    print(f"  [{msg.get('role')}] score={msg.get('score', 0):.4f} content={msg.get('content', '')[:60]}")
