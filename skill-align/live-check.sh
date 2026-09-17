#!/bin/bash
# live-check.sh — 运行态快速检查：health / skill list / skill search / PG 行数
set -uo pipefail
BASE="${MEMORY_URL:-http://localhost:8420}"
KEY="${MEMORY_ADMIN_KEY:?export MEMORY_ADMIN_KEY=<admin-key>}"
TEAM="${MEMORY_TEAM_ID:-team-demo0000001}"
AGT="${SKILL_E2E_AGENT_ID:-agt-e2etest000001}"
H1="Authorization: Bearer $KEY"
H2="Content-Type: application/json"
H3="x-tdai-service-id: default"
echo "1. health: $(curl -sS -o /dev/null -w '%{http_code}' $BASE/health)"
echo "2. skill list:"
curl -sS -X POST "$BASE/v3/skill/list" -H "$H1" -H "$H2" -H "$H3" -d "{\"team_id\":\"$TEAM\"}" | python3 -c "import sys,json;d=json.load(sys.stdin);items=d.get('data',{}).get('items',[]);print('   code=%s total=%s -> %s' % (d.get('code'), d.get('data',{}).get('total'), [i.get('name') for i in items]))"
echo "3. skill search:"
curl -sS -X POST "$BASE/v3/skill/search" -H "$H1" -H "$H2" -H "$H3" -d "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"query\":\"replication lag\",\"top_k\":3}" | python3 -c "import sys,json;items=json.load(sys.stdin).get('data',{}).get('items',[]);print('   hits:', [(i.get('name'), round(i.get('score',0),4)) for i in items])"
echo "4. PG 行数:"
: "${PG_CONNECTION_STRING:?export PG_CONNECTION_STRING=postgres://user:pass@host:5432/tdai_memory}"
docker exec -w /app tdai-memory-core node -e '
const { Pool } = require("pg");
(async () => {
  const pool = new Pool({ connectionString: process.argv[1] });
  for (const t of ["skills", "skill_vec", "l0_conversations", "l1_records"]) {
    const r = await pool.query("SELECT count(*)::int AS c FROM " + t);
    console.log("   " + t + "=" + r.rows[0].c);
  }
  await pool.end();
})().catch(e => { console.error("   " + e.message); process.exit(1); });
' "$PG_CONNECTION_STRING"
