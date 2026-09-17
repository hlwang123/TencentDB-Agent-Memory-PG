#!/bin/bash
# final-smoke.sh — 部署后冒烟：health + skill list + L0/L1/skills 计数 + 会话检索
set -uo pipefail
BASE="${MEMORY_URL:-http://localhost:8420}"
KEY="${MEMORY_ADMIN_KEY:?export MEMORY_ADMIN_KEY=<admin-key>}"
TEAM="${MEMORY_TEAM_ID:-team-demo0000001}"

echo "== health =="
curl -sS -o /dev/null -w "%{http_code}\n" "$BASE/health"
echo "== skill list（应保持可用）=="
curl -sS -X POST "$BASE/v3/skill/list" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -H "x-tdai-service-id: default" -d "{\"team_id\":\"$TEAM\"}" | python3 -c "import sys,json;d=json.load(sys.stdin);print('code:',d.get('code'),'| total:',d.get('data',{}).get('total'))"
echo "== L0/L1 计数（记忆主链路）=="
: "${PG_CONNECTION_STRING:?export PG_CONNECTION_STRING=postgres://user:pass@host:5432/tdai_memory}"
docker exec -w /app tdai-memory-core node -e '
const { Pool } = require("pg");
(async () => {
  const pool = new Pool({ connectionString: process.argv[1] });
  const l0 = await pool.query("SELECT count(*)::int AS c FROM l0_conversations");
  const l1 = await pool.query("SELECT count(*)::int AS c FROM l1_records");
  const sk = await pool.query("SELECT count(*)::int AS c FROM skills");
  console.log("l0=" + l0.rows[0].c + " l1=" + l1.rows[0].c + " skills=" + sk.rows[0].c);
  await pool.end();
})().catch(e => { console.error(e.message); process.exit(1); });
' "$PG_CONNECTION_STRING"
echo "== conversation/search 冒烟 =="
curl -sS -X POST "$BASE/v2/conversation/search" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -H "x-tdai-service-id: default" -d "{\"team_id\":\"$TEAM\",\"agent_id\":\"agt-demo0000001\",\"user_id\":\"usr-demo0000001\",\"query\":\"巡检\",\"top_k\":3}" | python3 -c "import sys,json;d=json.load(sys.stdin);print('code:',d.get('code'),'| items:',len(d.get('data',{}).get('items',[])))"
