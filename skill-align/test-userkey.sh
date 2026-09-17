#!/bin/bash
# test-userkey.sh — /v3/meta/auth/verify 鉴权检查
set -uo pipefail
BASE="${MEMORY_URL:-http://localhost:8420}"
KEY="${MEMORY_ADMIN_KEY:?export MEMORY_ADMIN_KEY=<admin-key>}"
echo "== auth/verify（body 带 user_key）=="
curl -sS -X POST "$BASE/v3/meta/auth/verify" -H "Authorization: Bearer $KEY" -H "x-tdai-service-id: default" -H "x-tdai-user-key: $KEY" -H "Content-Type: application/json" -d "{\"user_key\": \"$KEY\"}"
echo ""
