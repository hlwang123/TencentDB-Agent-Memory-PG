#!/bin/bash
# verify-extract.sh — 验证 Skill 提取结果可被检索（BM25 中英文查询）
set -uo pipefail
BASE="${MEMORY_URL:-http://localhost:8420}/v3/skill"
KEY="${MEMORY_ADMIN_KEY:?export MEMORY_ADMIN_KEY=<admin-key>}"
H1="Authorization: Bearer $KEY"
H2="Content-Type: application/json"
H3="x-tdai-service-id: default"
TEAM="${MEMORY_TEAM_ID:-team-demo0000001}"
AGT="${SKILL_E2E_AGENT_ID:-agt-e2etest000001}"

echo "== search: replication lag 巡检 =="
curl -sS -X POST "$BASE/search" -H "$H1" -H "$H2" -H "$H3" -d "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"query\":\"replication lag standby\",\"top_k\":3}" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('data', {}).get('items', [])
for it in items:
    print('hit:', it.get('name'), '| score:', round(it.get('score', 0), 4))
    print('snippet:', (it.get('snippet') or '')[:160])
print('(total', len(items), 'hits)')
"
echo "== search: 巡检 =="
curl -sS -X POST "$BASE/search" -H "$H1" -H "$H2" -H "$H3" -d "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"query\":\"巡检\",\"top_k\":3}" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('data', {}).get('items', [])
for it in items:
    print('hit:', it.get('name'), '| score:', round(it.get('score', 0), 4))
print('(total', len(items), 'hits)')
"
