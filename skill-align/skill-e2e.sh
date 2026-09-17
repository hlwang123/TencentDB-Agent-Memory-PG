#!/bin/bash
# skill-e2e.sh — /v3/skill/* 全链路 E2E 验证（PG 后端）
# 依赖环境变量：MEMORY_ADMIN_KEY（必填）、MEMORY_URL / MEMORY_TEAM_ID（可选）
set -uo pipefail

BASE="${MEMORY_URL:-http://localhost:8420}/v3/skill"
KEY="${MEMORY_ADMIN_KEY:?export MEMORY_ADMIN_KEY=<admin-key>}"
H1="Authorization: Bearer $KEY"
H2="Content-Type: application/json"
H3="x-tdai-service-id: default"
TEAM="${MEMORY_TEAM_ID:-team-demo0000001}"
USR="usr-skilltest"
AGT=""  # 由 [1.7] 动态注册获得

req() { # method path body label
  local method=$1 path=$2 body=$3 label=$4
  echo "── [$label] $method $path"
  if [ -n "$body" ]; then
    curl -sS -X POST "$BASE$path" -H "$H1" -H "$H2" -H "$H3" -d "$body" --max-time 30
  else
    curl -sS -X POST "$BASE$path" -H "$H1" -H "$H2" -H "$H3" -d '{}' --max-time 30
  fi
  echo ""
}

echo "═══ [1] list（期望空列表而非 404）═══"
req POST /list "{\"team_id\":\"$TEAM\"}" "list-initial"

echo "═══ [1.5] 清理残留（幂等重跑）═══"
LEFT_ID=$(curl -sS -X POST "$BASE/list" -H "$H1" -H "$H2" -H "$H3" --max-time 30 -d "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\"}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d.get('data',{}).get('items',[]):
    if it.get('name')=='pg-e2e-deploy-patrol':
        print(it.get('skill_id','')); break
" 2>/dev/null || echo "")
if [ -n "$LEFT_ID" ]; then
  LEFT_VER=$(curl -sS -X POST "$BASE/get" -H "$H1" -H "$H2" -H "$H3" --max-time 30 -d "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"skill_id\":\"$LEFT_ID\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('version',0))" 2>/dev/null || echo 0)
  echo "cleaning leftover $LEFT_ID v$LEFT_VER"
  req POST /delete "{\"user_id\":\"$USR\",\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"skill_id\":\"$LEFT_ID\",\"expected_version\":$LEFT_VER}" "cleanup"
fi

echo "═══ [1.7] 注册 agent 实体（ensureSkillAsset 前置条件）═══"
AGENT_RESP=$(curl -sS -X POST "${MEMORY_URL:-http://localhost:8420}/v3/meta/agent/create" -H "$H1" -H "$H2" -H "$H3" -H "x-tdai-user-key: $KEY" --max-time 30 -d "{
  \"team_id\": \"$TEAM\", \"owner_user_id\": \"usr-demo0000001\", \"name\": \"skill-e2e-agent\",
  \"description\": \"PG skill E2E 测试专用 agent\"
}")
echo "$AGENT_RESP"
AGT=$(echo "$AGENT_RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('data',{}).get('agent_id',''))" 2>/dev/null || echo "")
if [ -z "$AGT" ]; then
  # 可能已存在（幂等重跑）→ 按名查回
  AGT=$(curl -sS -X POST "${MEMORY_URL:-http://localhost:8420}/v3/meta/agent/list-by-team" -H "$H1" -H "$H2" -H "$H3" --max-time 30 -d "{\"team_id\":\"$TEAM\"}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d.get('data',{}).get('items',[]):
    if it.get('name')=='skill-e2e-agent':
        print(it.get('agent_id','')); break
" 2>/dev/null || echo "")
fi
echo "AGT=$AGT"
if [ -z "$AGT" ]; then echo "FATAL: 无法获得 agent_id"; exit 1; fi

echo "═══ [2] create ═══"
CREATE_RESP=$(curl -sS -X POST "$BASE/create" -H "$H1" -H "$H2" -H "$H3" --max-time 30 -d "{
  \"user_id\": \"$USR\", \"team_id\": \"$TEAM\", \"agent_id\": \"$AGT\",
  \"name\": \"pg-e2e-deploy-patrol\",
  \"content\": \"---\\nname: pg-e2e-deploy-patrol\\ndescription: 每天巡检 PostgreSQL 连接池、慢查询日志与磁盘水位\\n---\\n\\n# 部署巡检\\n\\n每天早上检查 PostgreSQL 连接池、慢查询日志和磁盘水位。\\n超过阈值时自动通知值班人员并生成巡检报告。\\n\",
  \"metadata\": {\"source\": \"pg-skill-e2e\"}
}")
echo "$CREATE_RESP"
SKILL_ID=$(echo "$CREATE_RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('data',{}).get('skill_id',''))" 2>/dev/null || echo "")
echo "skill_id=$SKILL_ID"

echo "═══ [3] get（期望 v1 + 中文内容完整）═══"
req POST /get "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"skill_id\":\"$SKILL_ID\",\"include_content\":true}" "get-v1"

echo "═══ [4] search bm25（中文查询'巡检'）═══"
req POST /search "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"query\":\"巡检 数据库\",\"top_k\":5}" "search-bm25"

echo "═══ [5] update（期望 v2，内容替换）═══"
req POST /update "{\"user_id\":\"$USR\",\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"skill_id\":\"$SKILL_ID\",\"expected_version\":1,\"content\":\"---\\nname: pg-e2e-deploy-patrol\\ndescription: 巡检范围扩展：连接池、慢查询、磁盘、主从延迟与备份完整性\\n---\\n\\n# 部署巡检 v2\\n\\n巡检范围扩展：连接池 + 慢查询 + 磁盘 + 主从延迟 + 备份完整性。\\n\"}" "update-v2"

echo "═══ [6] get（期望 v2）═══"
req POST /get "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"skill_id\":\"$SKILL_ID\",\"include_content\":true}" "get-v2"

echo "═══ [7] versions（期望 2 个版本）═══"
req POST /versions "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"skill_id\":\"$SKILL_ID\"}" "versions"

echo "═══ [8] search 再次（v2 内容关键词'主从延迟'）═══"
req POST /search "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"query\":\"主从延迟\",\"top_k\":5}" "search-v2"

echo "═══ [9] 重名创建（期望 SKILL_NAME_DUPLICATE / 42203）═══"
req POST /create "{\"user_id\":\"$USR\",\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"name\":\"pg-e2e-deploy-patrol\",\"content\":\"---\\nname: pg-e2e-deploy-patrol\\ndescription: dup test\\n---\\n\\ndup\\n\"}" "create-dup"

echo "═══ [10] delete（物理删除全部版本）═══"
req POST /delete "{\"user_id\":\"$USR\",\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\",\"skill_id\":\"$SKILL_ID\",\"expected_version\":2}" "delete"

echo "═══ [11] PG 表结构验证（经 memory-core 容器内 pg 客户端）═══"
: "${PG_CONNECTION_STRING:?export PG_CONNECTION_STRING=postgres://user:pass@host:5432/tdai_memory}"
docker exec tdai-memory-core node -e '
const { Pool } = require("pg");
(async () => {
  const pool = new Pool({ connectionString: process.argv[1] });
  const cols = await pool.query("SELECT column_name, data_type FROM information_schema.columns WHERE table_name='"'"'skills'"'"' ORDER BY ordinal_position");
  console.log("-- skills 列:");
  cols.rows.forEach(r => console.log("  " + r.column_name + " " + r.data_type));
  const idx = await pool.query("SELECT indexname FROM pg_indexes WHERE tablename IN ('"'"'skills'"'"','"'"'skill_vec'"'"') ORDER BY indexname");
  console.log("-- 索引:");
  idx.rows.forEach(r => console.log("  " + r.indexname));
  const c1 = await pool.query("SELECT count(*) AS c FROM skills");
  const c2 = await pool.query("SELECT count(*) AS c FROM skill_vec");
  console.log("-- 残留行数（期望 0）: skills=" + c1.rows[0].c + " skill_vec=" + c2.rows[0].c);
  await pool.end();
})().catch(e => { console.error("PG check failed:", e.message); process.exit(1); });
' "$PG_CONNECTION_STRING"
