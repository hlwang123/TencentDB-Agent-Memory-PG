#!/bin/bash
# skill-extract-e2e.sh — 对话提取链路验证
# 依赖环境变量：MEMORY_ADMIN_KEY（必填）、MEMORY_URL / MEMORY_TEAM_ID（可选）
set -uo pipefail

BASE="${MEMORY_URL:-http://localhost:8420}/v3/skill"
KEY="${MEMORY_ADMIN_KEY:?export MEMORY_ADMIN_KEY=<admin-key>}"
H1="Authorization: Bearer $KEY"
H2="Content-Type: application/json"
H3="x-tdai-service-id: default"
TEAM="${MEMORY_TEAM_ID:-team-demo0000001}"
USR="usr-skilltest"
AGT="${SKILL_E2E_AGENT_ID:-agt-e2etest000001}"   # skill-e2e.sh [1.7] 注册的 skill-e2e-agent
SESS="sess-extract-$(date +%s)"

echo "═══ [A] conversation/add（含工具调用对话）═══"
curl -sS -X POST "$BASE/conversation/add" -H "$H1" -H "$H2" -H "$H3" --max-time 30 -d @- <<JSONEOF
{
  "session_id": "$SESS",
  "user_id": "$USR",
  "team_id": "$TEAM",
  "agent_id": "$AGT",
  "messages": [
    {"role": "user", "content": "帮我检查一下主库到从库的复制延迟"},
    {"role": "tool_call", "content": "SELECT client_addr, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication", "tool_name": "sql_query", "tool_call_id": "tc-1"},
    {"role": "tool_result", "content": "client_addr=10.0.0.2 lag_bytes=1048576", "tool_call_id": "tc-1"},
    {"role": "assistant", "content": "从库 10.0.0.2 当前复制延迟约 1MB，属于正常范围。检查方法是查询 pg_stat_replication 视图，用 pg_wal_lsn_diff 计算当前 LSN 与 replay_lsn 的差值。"},
    {"role": "user", "content": "好的，这个检查方法记下来，以后巡检都用它"},
    {"role": "assistant", "content": "已记录：巡检时通过 pg_stat_replication + pg_wal_lsn_diff 检查主从复制延迟。"}
  ]
}
JSONEOF
echo ""

echo "═══ [B] force-archive（触发 LLM 提取）═══"
curl -sS -X POST "$BASE/conversation/force-archive" -H "$H1" -H "$H2" -H "$H3" --max-time 30 -d "{
  \"space_id\": \"default\", \"session_id\": \"$SESS\", \"user_id\": \"$USR\",
  \"team_id\": \"$TEAM\", \"agent_id\": \"$AGT\", \"reason\": \"e2e extract test\"
}"
echo ""

echo "═══ [C] 轮询提取结果（最长 120s）═══"
for i in $(seq 1 24); do
  sleep 5
  ITEMS=$(curl -sS -X POST "$BASE/list" -H "$H1" -H "$H2" -H "$H3" --max-time 15 -d "{\"team_id\":\"$TEAM\",\"agent_id\":\"$AGT\"}")
  COUNT=$(echo "$ITEMS" | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('total',0))" 2>/dev/null || echo 0)
  echo "[poll $i] skills=$COUNT"
  if [ "$COUNT" != "0" ]; then
    echo "$ITEMS" | python3 -m json.tool
    break
  fi
done

echo "═══ [D] 提取相关日志 ═══"
docker logs --since 3m tdai-memory-core 2>&1 | grep -iE "skill.*extract|extractor|conversation-add|archive" | grep -v "tcp.connect" | tail -12
