#!/bin/bash
# inspect-meta.sh — 检查容器内 sqlite/meta 残留与 metadata store 启动日志
echo "== /app/data 目录 =="
docker exec tdai-memory-core sh -c 'ls -la /app/data/ 2>/dev/null | head -20'
echo "== sqlite / meta 文件 =="
docker exec tdai-memory-core sh -c 'find /app -maxdepth 4 \( -name "*.db" -o -name "*.sqlite*" \) 2>/dev/null | head -10'
echo "== metadata store 相关日志（启动时）=="
docker logs tdai-memory-core 2>&1 | grep -iE "metadata|meta-store|user.?key|system.?user" | head -15
