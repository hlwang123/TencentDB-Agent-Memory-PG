#!/usr/bin/env python3
"""End-to-end test: write memory to PG, then search it back.

Run on the deploy server (needs docker access to the memory-core container):
    MEMORY_URL=http://127.0.0.1:8420 MEMORY_ADMIN_KEY=<admin-key> python test_pg_e2e.py
"""
import os
import subprocess
import json
import time

import requests

BASE = os.getenv("MEMORY_URL", "http://127.0.0.1:8420")
ADMIN_KEY = os.getenv("MEMORY_ADMIN_KEY", "")
USER_ID = "usr-testpg000001"
AGENT_ID = "agt-testpg000001"
TEAM_ID = os.getenv("MEMORY_TEAM_ID", "team-demo0000001")
SESSION_ID = "sess-pgtest-0001"
CONTAINER = os.getenv("MEMORY_CORE_CONTAINER", "tdai-memory-core")

headers = {
    "Content-Type": "application/json",
    "Authorization": f"Bearer {ADMIN_KEY}",
    "x-tdai-service-id": "default",
    "x-tdai-team-id": TEAM_ID,
    "x-tdai-user-id": USER_ID,
    "x-tdai-agent-id": AGENT_ID,
}

def call(path, body=None):
    r = requests.post(f"{BASE}{path}", headers=headers, json=body or {})
    return r.status_code, r.json()

# Step 1: Add conversation
print("=== Step 1: Add conversation ===")
code, resp = call("/v2/conversation/add", {
    "sessionId": SESSION_ID,
    "messages": [
        {"role": "user", "content": "PostgreSQL迁移测试：今天我们在测试pgvector存储后端是否正常工作"},
        {"role": "assistant", "content": "好的，pgvector存储后端测试正在进行中。所有9张表已创建成功。"}
    ]
})
print(f"Status: {code}")
print(f"Response: {json.dumps(resp, ensure_ascii=False)[:500]}")

# Wait for processing
print("\n=== Waiting 5s for processing ===")
time.sleep(5)

# Step 2: Search conversations
print("\n=== Step 2: Search conversations ===")
code, resp = call("/v2/conversation/search", {
    "query": "pgvector存储测试",
    "limit": 5
})
print(f"Status: {code}")
print(f"Response: {json.dumps(resp, ensure_ascii=False)[:800]}")

# Step 3: Atomic search (recall)
print("\n=== Step 3: Atomic search (recall) ===")
code, resp = call("/v2/atomic/search", {
    "query": "PostgreSQL迁移",
    "limit": 5
})
print(f"Status: {code}")
print(f"Response: {json.dumps(resp, ensure_ascii=False)[:800]}")

# Step 4: Check PG tables directly (local docker exec on the deploy server;
# set PG_CONNECTION_STRING to enable)
print("\n=== Step 4: Check PG via container ===")
pg_conn = os.getenv("PG_CONNECTION_STRING", "")
if pg_conn:
    node_script = (
        "const{Pool}=require('pg');"
        f"const p=new Pool({{connectionString:{json.dumps(pg_conn)}}});"
        "(async()=>{"
        "for(const t of ['l0_conversations','l1_records']){"
        "const r=await p.query('SELECT count(*)::int c FROM '+t);"
        "console.log(t+':',r.rows[0].c)}"
        "await p.end()})().catch(e=>{console.error(e.message);process.exit(1)})"
    )
    check = subprocess.run(
        ["docker", "exec", "-w", "/app", CONTAINER, "node", "-e", node_script],
        capture_output=True, text=True,
    )
    print(check.stdout)
    if check.stderr:
        print("STDERR:", check.stderr[:200])
else:
    print("(skipped: set PG_CONNECTION_STRING to check tables via the container)")

print("\n=== Done ===")
