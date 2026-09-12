# TDAI Memory Core — PostgreSQL 迁移部署文档

[English](README_EN.md) | 简体中文

> **开源声明**：本仓库是 [TencentDB-Agent-Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory)（MIT 许可）的
> PostgreSQL 存储后端迁移补丁与部署脚本集合。`src/`、`patches/` 中的部分文件修改自上游源码，
> 许可与衍生关系说明见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。

## 1. 概述

本文档描述如何将 TDAI Memory Core 的存储后端从 SQLite（sqlite-vec + FTS5）迁移到 PostgreSQL 16 + pgvector + tsvector。

### 1.1 架构

```
┌──────────────┐     ┌──────────────────────────┐     ┌─────────────────┐
│  Panel UI    │────▶│  Memory Core (8420)      │────▶│  PostgreSQL 16  │
│  (18125)     │     │  agentmemory/memory-core  │     │  <pg-host>      │
└──────────────┘     │  storeBackend=postgres    │     │  tdai_memory DB │
                     │  pgvector + tsvector      │     │  pgvector 0.8.2 │
┌──────────────┐     └──────────────────────────┘     └─────────────────┘
│  Embedding   │               ▲
│  BGE-M3      │               │
│  (8121)      │     ┌────────┴─────────┐
└──────────────┘     │  LLM (DashScope)  │
                     │  qwen3.5-27b      │
                     └──────────────────┘
```

### 1.2 组件清单

| 组件 | 镜像/版本 | 端口 | 说明 |
|------|-----------|------|------|
| Memory Core | `agentmemory/memory-core:latest` | 8420 | 记忆网关，PG 后端 |
| Memory Hub | `agentmemory/memory-hub:latest` | 18125 | Panel UI |
| Memory Proxy | `agentmemory/memory-proxy:latest` | 8096 | Claude Code 代理 |
| Embedding | BGE-M3 (本地) | 8121 | 向量嵌入服务 |
| PostgreSQL | 16.13 (Debian) | 5432 | 数据库 + pgvector |

### 1.3 关键地址

| 服务 | 地址（按实际部署替换） |
|------|------|
| Memory Core API | `http://<server-ip>:8420` |
| Panel UI | `http://<server-ip>:18125` |
| PostgreSQL | `postgres://postgres:<password>@<pg-host>:5432/tdai_memory` |
| Embedding | `http://<server-ip>:8121/v1/` |
| LLM (DashScope) | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| Admin Key | 首次启动由 `start-memory-core.sh` 自动生成，保存到 `deploy/.admin-key` |

---

## 2. 目录结构

```
TAM/
├── README.md / README_EN.md           ← 本文档（中文 / English）
├── LICENSE / NOTICE                   ← MIT 许可 + 上游衍生说明
├── src/                               ← 从容器提取的已修补源码
│   ├── config.ts                      ← StoreBackend 类型 + PostgresConfig + 配置解析
│   ├── gateway/
│   │   └── server.ts                  ← STORE_MODE 环境变量检查
│   ├── utils/
│   │   └── manifest.ts                ← StoreConfigSnapshot + ManifestStoreInfo 类型
│   └── core/store/
│       ├── pg-store.ts                ← ★ 新增：PG 存储实现 (IMemoryStore 接口)
│       ├── factory.ts                 ← createStoreBundle 加 postgres case
│       └── store-pool.ts              ← StoreMode + createPostgresStore + getStore 分支
├── patches/                           ← 补丁文件 + 打补丁脚本
│   ├── pg-store.ts                    ← 同 src/core/store/pg-store.ts (部署用)
│   ├── config.ts                      ← 同 src/config.ts (部署用)
│   ├── factory.ts                     ← 同 src/core/store/factory.ts (部署用)
│   ├── store-pool.ts                  ← 同 src/core/store/store-pool.ts (部署用)
│   ├── manifest.ts                    ← 同 src/utils/manifest.ts (部署用)
│   ├── server.ts                      ← 同 src/gateway/server.ts (部署用)
│   ├── pg-store-original.ts           ← 原始合并版 pg-store.ts (未应用 bugfix)
│   ├── patch-all.js                   ← 主补丁脚本 (config/factory/store-pool)
│   ├── fix-factory.js                 ← factory.ts postgres case 插入
│   ├── fix-config.js                  ← config.ts + manifest.ts 修复
│   ├── fix-manifest.js                ← manifest.ts 类型修复
│   ├── fix-server.js                  ← server.ts STORE_MODE 检查
│   ├── fix-pg-import.cjs              ← 修复 require("pg") → ES import
│   ├── fix-limit.cjs                  ← 修复 LIMIT 参数类型 (加 ::int)
│   ├── fix-limit2.cjs                 ← 修复 ++i 模式的 LIMIT/OFFSET
│   ├── fix-params.cjs                 ← 修复 buildIsoClause 偏移 + ::vector cast
│   ├── fix-timestamp.cjs              ← 修复 bigint timestamp → Number()
│   ├── fix-timestamp2.cjs             ← 修复 ?? 0 模式的 timestamp
│   ├── fix-yaml.py                    ← YAML 配置修复脚本
│   └── create-db.js                   ← PG 数据库创建脚本 (读 PG_CONNECTION_STRING)
└── deploy/                            ← 部署脚本
    ├── .env.example                   ← 环境变量模板 (复制为 .env 后填写)
    ├── start-all.sh                   ← 启动全部服务
    ├── start-memory-core.sh           ← ★ 启动 memory-core (已修改支持 PG)
    ├── start-memory-hub.sh            ← 启动 panel UI
    ├── start-proxy.sh                 ← 启动 proxy
    ├── stop-all.sh                    ← 停止全部服务
    ├── apply-pg-patches.sh            ← ★ 自动应用 PG 迁移补丁
    ├── _lib.sh                        ← 部署库函数
    └── verify.sh                      ← 部署验证脚本
├── db/
│   └── schema.sql                     ← PG 数据库 DDL (9 张表 + 索引)
└── scripts/                           ← 演示应用
    ├── memory_client.py               ← Memory V2 API 客户端
    ├── main.py                        ← LangGraph Chat Agent (配置读环境变量)
    └── index.html                     ← 聊天 Web 界面
```

> 注：`.env`、`.admin-key`、`tdai-gateway.yaml` 含本机密钥，不入库（见 `.gitignore`），
> 首次部署时由 `start-memory-core.sh` 自动生成。

---

## 3. 前置条件

### 3.1 PostgreSQL 服务器

需要一台 PostgreSQL 16+ 服务器，并安装以下扩展：

```sql
-- 创建数据库
CREATE DATABASE tdai_memory;

-- 连接到 tdai_memory 数据库后执行：
CREATE EXTENSION IF NOT EXISTS vector;      -- pgvector >= 0.8.0
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- pg_trgm >= 1.6
```

验证：
```sql
SELECT extname, extversion FROM pg_extension WHERE extname IN ('vector', 'pg_trgm');
-- 预期: vector | 0.8.2, pg_trgm | 1.6
```

### 3.2 Docker 环境

部署服务器需要安装 Docker。Memory Core 容器通过 Docker 网络访问 PG。

### 3.3 Embedding 服务

需要 BGE-M3 embedding 服务（1024 维），提供 OpenAI 兼容 API。

---

## 4. 部署步骤

### 4.1 使用原始镜像 + 自动补丁（推荐）

```bash
# 1. 复制部署文件到服务器
scp -r deploy/ root@<server>:/root/tdai-deploy/
scp -r patches/ root@<server>:/root/tdai-deploy/.memory-core-patches/
scp -r db/ root@<server>:/root/tdai-deploy/db/

# 2. 初始化 PG 数据库（如果尚未创建）
psql -h <pg_host> -U postgres -d tdai_memory -f db/schema.sql
# 或者用补丁脚本（读 PG_CONNECTION_STRING 环境变量）：
# PG_CONNECTION_STRING="postgres://postgres:<password>@<pg-host>:5432/postgres" node patches/create-db.js

# 3. 配置环境变量
cp deploy/.env.example deploy/.env   # 然后编辑：
#    - PG_CONNECTION_STRING : PG 连接串（必填）
#    - MEMORY_LLM_*         : LLM 配置
#    - EMBEDDING_*          : Embedding 服务配置

# 4. 启动（脚本会自动：创建容器 → sendDimensions hotfix → 应用 PG 补丁 → 初始化 admin）
cd /root/tdai-deploy && bash start-memory-core.sh
```

### 4.2 配置说明

#### .env 关键变量

```bash
# 镜像
MEMORY_CORE_IMAGE=agentmemory/memory-core:latest
MEMORY_CORE_PORT=8420

# PostgreSQL（必填）
PG_CONNECTION_STRING=postgres://postgres:<password>@<pg-host>:5432/tdai_memory

# LLM
MEMORY_LLM_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
MEMORY_LLM_API_KEY=<your-api-key>
MEMORY_LLM_MODEL=qwen3.5-27b

# Embedding
EMBEDDING_PROVIDER=openai
EMBEDDING_BASE_URL=http://<server-ip>:8121/v1/
EMBEDDING_MODEL=bge-m3
EMBEDDING_DIMENSIONS=1024
EMBEDDING_SEND_DIMENSIONS=false

# 数据卷
MEMORY_CORE_VOLUME=tdai-memory-core-data
```

#### tdai-gateway.yaml PG 配置（由 start-memory-core.sh 从 .env 自动生成）

```yaml
memory:
  storeBackend: postgres
  postgres:
    connectionString: "postgres://postgres:<password>@<pg-host>:5432/tdai_memory"
```

#### 环境变量

容器启动时需要设置 `STORE_MODE=postgres`，由 `start-memory-core.sh` 自动注入。

---

## 5. 补丁详情

### 5.1 修改的源文件 (6 个)

| 文件 | 容器路径 | 修改内容 |
|------|----------|----------|
| `pg-store.ts` | `/app/src/core/store/pg-store.ts` | **新增**：PG 存储实现，~670 行，实现完整 `IMemoryStore` 接口 |
| `config.ts` | `/app/src/config.ts` | `StoreBackend` 类型加 `"postgres"`；新增 `PostgresConfig` 接口；配置解析加 `postgres` 字段 |
| `factory.ts` | `/app/src/core/store/factory.ts` | `createStoreBundle` switch 加 `case "postgres"` |
| `store-pool.ts` | `/app/src/core/store/store-pool.ts` | `StoreMode` 加 `"postgres"`；新增 `createPostgresStore()` 方法；`getStore` 分支处理 |
| `manifest.ts` | `/app/src/utils/manifest.ts` | `StoreConfigSnapshot` 和 `ManifestStoreInfo` 类型加 postgres |
| `server.ts` | `/app/src/gateway/server.ts` | `STORE_MODE` env var 检查加 `"postgres"` |

### 5.2 补丁应用流程

`start-memory-core.sh` 执行顺序：

```
1. 生成 tdai-gateway.yaml (含 storeBackend: postgres + connectionString)
2. docker run 创建容器 (含 STORE_MODE=postgres)
3. 等待容器健康
4. 应用 sendDimensions hotfix (sed 插入 + 重启)
5. 调用 apply-pg-patches.sh:
   a. npm install pg --save
   b. docker cp 6 个补丁文件到容器
   c. docker restart
   d. 等待健康检查
6. 初始化 admin user
7. 验证 admin key
```

---

## 6. 数据库 Schema

### 6.1 表结构

| 表名 | 说明 | 关键列 |
|------|------|--------|
| `l0_conversations` | L0 原始对话 | `record_id`, `message_text`, `embedding(vector)`, `message_tsv(tsvector)` |
| `l1_records` | L1 提取记忆 | `record_id`, `content`, `embedding(vector)`, `content_tsv(tsvector)` |
| `memory_audit` | 审计日志 | `audit_id`, `record_id`, `action`, `updated_at_ms` |
| `embedding_meta` | 嵌入元数据 | `key`, `value` |
| `entity_teams` | 团队实体 | `team_id`, `name`, `user_ids_json` |
| `entity_users` | 用户实体 | `user_id`, `name`, `team_ids_json` |
| `entity_agents` | Agent 实体 | `agent_id`, `team_id`, `prompt` |
| `entity_tasks` | 任务实体 | `task_id`, `team_id`, `status` |
| `entity_knowledge` | 知识实体 | `knowledge_id`, `type`, `service_url` |

### 6.2 索引

- **FTS 索引**: `GIN` 索引 on `message_tsv` / `content_tsv`
- **向量索引**: `IVFFlat` 索引 on `embedding` (cosine, lists=100)
- **B-tree 索引**: session_key, session_id, user_id+agent_id+session_id, timestamp, updated_time 等

### 6.3 搜索机制

- **FTS 搜索**: `tsvector` + `websearch_to_tsquery('simple', $query)` + `ts_rank` 排序
- **向量搜索**: `embedding <=> $query_vector::vector` (cosine distance)
- **混合搜索**: FTS + vector 并行搜索，合并结果

---

## 7. API 使用

### 7.1 认证

所有 API 请求需要以下 header：

```python
headers = {
    "Content-Type": "application/json",
    "Authorization": "Bearer <your-admin-key>",
    "x-tdai-service-id": "default",
    "x-tdai-team-id": "team-<teamId>",
    "x-tdai-user-id": "usr-<userId>",
    "x-tdai-agent-id": "agt-<agentId>",
}
```

### 7.2 核心接口

| 接口 | 方法 | 说明 |
|------|------|------|
| `/v2/conversation/add` | POST | 添加对话 (L0) |
| `/v2/conversation/search` | POST | 搜索对话 (FTS + vector) |
| `/v2/atomic/search` | POST | 搜索记忆 (L1, FTS + vector) |
| `/v2/core/read` | POST | 读取 persona |
| `/health` | GET | 健康检查 |

> 简单验证：`curl http://<server-ip>:8420/health`；
> 或运行 `scripts/main.py`（LangGraph 演示应用，配置见环境变量 `MEMORY_URL` / `MEMORY_ADMIN_KEY` 等）。

---

## 8. 运维

### 8.1 查看日志

```bash
docker logs -f tdai-memory-core
# 关键日志:
# [memory-tdai][pg] Initialized (dims=1024)
# backend=postgres, embedding=openai
# mode=postgres
```

### 8.2 检查 PG 数据

```bash
# 进入容器执行
docker exec -w /app tdai-memory-core node -e "
const{Pool}=require('pg');
const p=new Pool({connectionString:'postgres://postgres:<password>@<pg-host>:5432/tdai_memory'});
p.query('SELECT COUNT(*) FROM l0_conversations').then(r=>{console.log('L0:',r.rows[0].count);p.end()});
p.query('SELECT COUNT(*) FROM l1_records').then(r=>{console.log('L1:',r.rows[0].count);p.end()});
"
```

### 8.3 容器重建后补丁丢失？

如果手动 `docker rm` 容器，重新执行 `start-memory-core.sh` 会自动重新应用所有补丁。

### 8.4 切换回 SQLite

修改 `.env` 或 `start-memory-core.sh`：
1. YAML 配置中 `storeBackend: postgres` → `storeBackend: sqlite`
2. 删除 `STORE_MODE=postgres` 环境变量
3. 注释掉 `apply-pg-patches.sh` 调用

---

## 9. 已知限制

1. **Skill wiring 跳过**: 日志中 `Skill wiring skipped: vectorStore does not expose getRawDb()` — PG 后端不支持 SQLite 特有的 `getRawDb()` 接口，Skill 模块功能受限（不影响核心记忆功能）
2. **容器内补丁非持久化**: 通过 `docker commit` 自行固化的镜像可包含补丁，但用原始镜像每次重建容器都需要重新应用（`start-memory-core.sh` 会自动完成）
3. **jieba 分词**: FTS 使用 `tokenizeForFts` (jieba) 分词后存入 `message_segmented`，再生成 `tsvector`；查询时同样分词后用 `websearch_to_tsquery('simple', ...)`

---

## 10. 版本信息

| 组件 | 版本 |
|------|------|
| Memory Core 镜像 | `agentmemory/memory-core:latest` (基础) |
| PostgreSQL | 16.13 (Debian) |
| pgvector | 0.8.2 |
| pg_trgm | 1.6 |
| Node.js (容器内) | v22.23.2 |
| tsx | ESM 模式 |
| pg npm 包 | 最新版 |
