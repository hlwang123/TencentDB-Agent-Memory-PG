#!/usr/bin/env bash
# apply-pg-patches.sh — 在 memory-core 容器内应用 PostgreSQL 迁移补丁
# 用法: ./apply-pg-patches.sh [container_name]
# 补丁文件位于 .memory-core-patches/ 目录
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/.memory-core-patches"
CONTAINER="${1:-tdai-memory-core}"

echo "[pg-patch] Applying PostgreSQL migration patches to $CONTAINER..."

# 1. 安装 pg npm 包
echo "[pg-patch] Installing pg npm package..."
docker exec "$CONTAINER" npm install pg --save 2>&1 | tail -3

# 2. 复制补丁文件到容器
echo "[pg-patch] Copying patched source files..."
docker cp "$PATCH_DIR/pg-store.ts" "$CONTAINER:/app/src/core/store/pg-store.ts"
docker cp "$PATCH_DIR/config.ts" "$CONTAINER:/app/src/config.ts"
docker cp "$PATCH_DIR/factory.ts" "$CONTAINER:/app/src/core/store/factory.ts"
docker cp "$PATCH_DIR/store-pool.ts" "$CONTAINER:/app/src/core/store/store-pool.ts"
docker cp "$PATCH_DIR/manifest.ts" "$CONTAINER:/app/src/utils/manifest.ts"
docker cp "$PATCH_DIR/server.ts" "$CONTAINER:/app/src/gateway/server.ts"
# [pg-align] Skill 模块 PG 后端
docker cp "$PATCH_DIR/pg-skill-store.ts" "$CONTAINER:/app/src/core/skill/pg-skill-store.ts"
docker cp "$PATCH_DIR/tdai-core.ts" "$CONTAINER:/app/src/core/tdai-core.ts"

# 3. 重启容器使补丁生效
echo "[pg-patch] Restarting container..."
docker restart "$CONTAINER" >/dev/null

# 4. 等待健康检查
echo "[pg-patch] Waiting for container to be healthy..."
for i in $(seq 1 30); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:8420/health" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    echo "[pg-patch] Container healthy after ${i}s"
    exit 0
  fi
  sleep 1
done
echo "[pg-patch] WARNING: Container not healthy after 30s"
exit 1
