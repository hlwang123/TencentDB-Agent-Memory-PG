# TencentDB-Agent-Memory-PG

[TencentDB-Agent-Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory) 的全 PostgreSQL 迁移与部署工具包

[English](README_EN.md) | 简体中文

> **开源声明**：本仓库是 [TencentDB-Agent-Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory)（MIT 许可）的
> 全 PostgreSQL 迁移与部署工具包——补丁全部打在唯一有存储后端的组件 TDAI Memory Core 上
> （存储面 + Skill 模块 + 元数据面），Memory Hub / Memory Proxy 无自有存储、原样部署；
> 三件套整体即**完整的 TencentDB-Agent-Memory 全 PG 栈，无 SQLite 依赖**。
> `src/`、`patches/` 中的部分文件修改自上游源码，
> 许可与衍生关系说明见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。
>
> **上游进展**：本仓库的源码级集成已向上游提交
> PR [#1387](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1387)
> （PostgreSQL 存储后端 + Skill 模块对齐）与后续
> PR [#1466](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1466)
> （元数据面 PostgreSQL 后端，补齐"全 PG、无 SQLite 依赖"的最后一块）。两个 PR
> 合并发版后，可直接配置 `storeBackend: postgres` + `TDAI_METADATA_POSTGRES_URI`
> 原生使用，无需本仓库的补丁链；在此之前，本文档的补丁部署方式仍然有效。

## 1. 概述

本文档描述如何将 TDAI Memory Core 从 SQLite 完整迁移到 PostgreSQL 16 + pgvector + tsvector，覆盖三个层面：

1. **存储面**（L0/L1 记忆 + FTS/向量混合检索，§5.1）
2. **Skill 模块**（程序性记忆：技能/经验的存取与版本管理，§5.2）
3. **元数据面**（v3 metadata：用户/团队/Agent/资产/ACL 等，含 admin user_key，§5.4）

三者全部落 PG 后即实现**全 PG 部署、无 SQLite 依赖**——数据不再锁死在容器 volume 内，可备份、可高可用、可 SQL 直查。

配套的 Memory Hub（Panel UI）与 Memory Proxy（Claude Code 代理）没有自有存储，原样部署即可——因此对 memory-core 一个组件完成 PG 化，即得到**完整的 TencentDB-Agent-Memory 全 PG 栈**（本仓库部署脚本会拉起全部三件套，见 §4）。

### 1.1 架构

```
┌──────────────┐     ┌──────────────────────────┐     ┌─────────────────┐
│  Panel UI    │────▶│  Memory Core (8420)      │────▶│  PostgreSQL 16  │
│  (18125)     │     │  agentmemory/memory-core  │     │  <pg-host>      │
└──────────────┘     │  storeBackend=postgres    │     │  tdai_memory DB │
                     │  metadata=postgres        │     │  + meta schemas │
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
| Memory Core | `agentmemory/memory-core:latest` | 8420 | 记忆网关，全 PG 后端（存储 + 元数据） |
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
├── docs/
│   └── tam-pg-support.md              ← TAM 特性介绍与 PostgreSQL 支持说明
├── src/                               ← 从容器提取的已修补源码
│   ├── config.ts                      ← StoreBackend 类型 + PostgresConfig + 配置解析
│   ├── gateway/
│   │   ├── server.ts                  ← STORE_MODE 环境变量检查
│   │   └── metadata-env.ts            ← ★ 新增：TDAI_METADATA_POSTGRES_URI 环境变量注入
│   ├── utils/
│   │   └── manifest.ts                ← StoreConfigSnapshot + ManifestStoreInfo 类型
│   ├── core/
│   │   ├── tdai-core.ts               ← ★ 修改：Skill wiring 增加 getPgPool() 分支
│   │   ├── skill/
│   │   │   └── pg-skill-store.ts      ← ★ 新增：Skill 数据层 PG 实现
│   │   └── store/
│   │       ├── pg-store.ts            ← ★ 新增：PG 存储实现 (IMemoryStore + getPgPool 逃生舱)
│   │       ├── factory.ts             ← createStoreBundle 加 postgres case
│   │       └── store-pool.ts          ← StoreMode + createPostgresStore + getStore 分支
│   ├── metadata/                      ← ★ 新增：元数据面 (v3 metadata) PG 后端
│   │   └── store/
│   │       ├── postgres-adapter.ts    ← ★ 新增：PostgresMetadataStore (schema-per-instance)
│   │       ├── interface.ts           ← MetadataBackend 类型加 "postgres"
│   │       ├── db-name.ts             ← resolvePostgresSchemaName (63 字节截断)
│   │       ├── factory.ts             ← createMetadataStore postgres case + 三选一互斥
│   │       └── relation-id-insert.ts  ← PG 唯一冲突 (23505) 按 pkey 约束名识别
├── patches/                           ← 补丁文件 + 打补丁脚本
│   ├── pg-store.ts                    ← 同 src/core/store/pg-store.ts (部署用)
│   ├── config.ts                      ← 同 src/config.ts (部署用)
│   ├── factory.ts                     ← 同 src/core/store/factory.ts (部署用)
│   ├── store-pool.ts                  ← 同 src/core/store/store-pool.ts (部署用)
│   ├── manifest.ts                    ← 同 src/utils/manifest.ts (部署用)
│   ├── server.ts                      ← 同 src/gateway/server.ts (部署用)
│   ├── tdai-core.ts                   ← 同 src/core/tdai-core.ts (部署用)
│   ├── pg-skill-store.ts              ← 同 src/core/skill/pg-skill-store.ts (部署用)
│   ├── pg-metadata-store.ts           ← 同 src/metadata/store/postgres-adapter.ts (部署用)
│   ├── metadata-interface.ts          ← 同 src/metadata/store/interface.ts (部署用)
│   ├── metadata-db-name.ts            ← 同 src/metadata/store/db-name.ts (部署用)
│   ├── metadata-factory.ts            ← 同 src/metadata/store/factory.ts (部署用)
│   ├── metadata-relation-id-insert.ts ← 同 src/metadata/store/relation-id-insert.ts (部署用)
│   ├── gateway-metadata-env.ts        ← 同 src/gateway/metadata-env.ts (部署用)
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
├── deploy/                            ← 部署脚本
│   ├── .env.example                   ← 环境变量模板 (复制为 .env 后填写)
│   ├── start-all.sh                   ← 启动全部服务
│   ├── start-memory-core.sh           ← ★ 启动 memory-core (已修改支持 PG)
│   ├── start-memory-hub.sh            ← 启动 panel UI
│   ├── start-proxy.sh                 ← 启动 proxy
│   ├── stop-all.sh                    ← 停止全部服务
│   ├── apply-pg-patches.sh            ← ★ 自动应用 PG 迁移补丁 (14 个文件)
│   ├── _lib.sh                        ← 部署库函数
│   └── verify.sh                      ← 部署验证脚本
├── db/
│   └── schema.sql                     ← PG 数据库 DDL (9 张表 + 索引)
├── skill-align/                       ← ★ Skill 模块 PG 对齐验证套件 (E2E/冒烟脚本)
├── example/                           ← TAM 记忆 Agent 演示应用 (FastAPI + LangGraph + Web)
└── scripts/                           ← 测试/演示脚本
    ├── memory_client.py               ← Memory V2 API 客户端
    ├── main.py                        ← LangGraph Chat Agent (TAM + Skill-Hub 双记忆)
    ├── index.html                     ← 聊天 Web 界面
    ├── test_pg_e2e.py                 ← PG 端到端测试 (配置读环境变量)
    └── test_search.py                 ← 搜索测试 (配置读环境变量)
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

# 元数据面（v3 metadata）PG 后端
# 不配置/留空 = 复用上面的 PG_CONNECTION_STRING（默认全 PG）；
# 显式置为空字符串 = 回退容器 volume 内 SQLite。
# METADATA_PG_CONNECTION_STRING=
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

> 注：以下 14 个补丁面向当前上游容器镜像内的源码布局（§5.1 存储面 8 个 + §5.4 元数据面
> 6 个）。上游 PR [#1387](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1387)
> 按上游最新目录规范将存储面新增文件置于 `src/core/store/postgres/{memory-store,skill-store}.ts`；
> 元数据面 PG 化已提交上游 PR
> [#1466](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1466)
> （`src/metadata/store/postgres-adapter.ts`）。实现均与本仓库补丁等价。

### 5.1 存储面：修改的源文件 (8 个)

| 文件 | 容器路径 | 修改内容 |
|------|----------|----------|
| `pg-store.ts` | `/app/src/core/store/pg-store.ts` | **新增**：PG 存储实现，~670 行，实现完整 `IMemoryStore` 接口；新增 `getPgPool()` 逃生舱（暴露连接池 + 维度，供 Skill 模块复用） |
| `config.ts` | `/app/src/config.ts` | `StoreBackend` 类型加 `"postgres"`；新增 `PostgresConfig` 接口；配置解析加 `postgres` 字段 |
| `factory.ts` | `/app/src/core/store/factory.ts` | `createStoreBundle` switch 加 `case "postgres"` |
| `store-pool.ts` | `/app/src/core/store/store-pool.ts` | `StoreMode` 加 `"postgres"`；新增 `createPostgresStore()` 方法；`getStore` 分支处理 |
| `manifest.ts` | `/app/src/utils/manifest.ts` | `StoreConfigSnapshot` 和 `ManifestStoreInfo` 类型加 postgres |
| `server.ts` | `/app/src/gateway/server.ts` | `STORE_MODE` env var 检查加 `"postgres"` |
| `tdai-core.ts` | `/app/src/core/tdai-core.ts` | **修改**：Skill wiring 分支——SQLite 走 `getRawDb()`，PostgreSQL 走 `getPgPool()` 构造 `PgSkillStore`（与 SQLite 角色对等） |
| `pg-skill-store.ts` | `/app/src/core/skill/pg-skill-store.ts` | **新增**：Skill 数据访问层的 PG 实现，与 `SqliteSkillStore` 语义 1:1 对齐 |

### 5.2 Skill 模块的 PG 对齐（pg-align）

TAM 的 Skill 模块（程序性记忆：技能/经验的存储、检索、版本管理、对话提取）原本只支持
SQLite——核心初始化时通过 `VectorStore.getRawDb()` 拿到底层数据库句柄。PG 后端此前因此跳过
Skill wiring（日志 `Skill wiring skipped`）。

对齐方案（不侵入官方接口）：

| 项 | SQLite 版 | PG 版（pg-skill-store.ts） |
|----|-----------|---------------------------|
| 逃生舱 | `getRawDb()` → `DatabaseSync` | `PgMemoryStore.getPgPool()` → 共享同一 `pg.Pool` + 维度 |
| 全文检索 | FTS5 | `skills.fts_segmented`（jieba 预分词）+ `fts_tsv` 生成列 + GIN（随行更新自动维护） |
| 向量检索 | vec0 虚拟表 | 独立表 `skill_vec(skill_id PK, embedding vector(dim))` + IVFFlat cosine；并实现 embedding / hybrid(RRF) 检索路径 |
| 写串行化 | `BEGIN IMMEDIATE` 全库串行 | 事务级 advisory lock（`pg_advisory_xact_lock(hashtext(skill_id))`）按 skill_id 串行 |
| 时间戳 | INTEGER ms | BIGINT（`Date.now()` 超 int4），读回 `Number()` |
| DDL | 同步建表 | `init()` 异步 DDL，方法内部 `await readyPromise`，DDL 完成前请求排队 |

表结构由 `PgSkillStore.init()` 自动创建（`skills`（多版本同表，`is_head` 标记当前版本）+
`skill_vec` 向量表），无需手工执行 DDL。启动成功的标志日志：

```
[memory-tdai] [pg-align] Skill store backend: PgSkillStore (dimensions=1024)
```

全链路验证脚本见 `skill-align/`（`skill-e2e.sh`：CRUD/版本/中英文 BM25 检索/重名冲突/物理
删除 + PG 表结构校验；`skill-extract-e2e.sh`：对话 → LLM 提取 skill）。

### 5.3 补丁应用流程

`start-memory-core.sh` 执行顺序：

```
1. 生成 tdai-gateway.yaml (含 storeBackend: postgres + connectionString)
2. docker run 创建容器 (含 STORE_MODE=postgres + TDAI_METADATA_POSTGRES_URI)
3. 等待容器健康
4. 应用 sendDimensions hotfix (sed 插入 + 重启)
5. 调用 apply-pg-patches.sh:
   a. npm install pg --save
   b. docker cp 14 个补丁文件到容器 (存储面 8 + 元数据面 6, 见 §5.4)
   c. docker restart
   d. 等待健康检查
6. 初始化 admin user
7. 验证 admin key
```

### 5.4 元数据面 PG 化（pg-metadata，6 个文件）

v3 metadata（user/team/agent/task/asset/acl 等实体与关系，含 admin user_key、实例注册）
原本只有 SQLite / MongoDB 两个后端——即使存储面已切 PG，元数据仍落在容器 volume 内的
SQLite 文件里。本组补丁新增 `PostgresMetadataStore`（实现容器版完整 `IMetadataStore`
接口），实现**全 PG 部署、无 SQLite 依赖**。

| 文件 | 容器路径 | 修改内容 |
|------|----------|----------|
| `pg-metadata-store.ts` | `/app/src/metadata/store/postgres-adapter.ts` | **新增**：`PostgresMetadataStore`；SQL 方言自动转换（`?`→`$n`、`meta_*` 表名自动加 schema 前缀、`INSERT OR IGNORE`→`ON CONFLICT DO NOTHING`、COUNT 的 bigint→Number） |
| `metadata-interface.ts` | `/app/src/metadata/store/interface.ts` | `MetadataBackend` 类型加 `"postgres"` |
| `metadata-db-name.ts` | `/app/src/metadata/store/db-name.ts` | 新增 `resolvePostgresSchemaName()`（实例 id 清洗 + PG 标识符 63 字节截断） |
| `metadata-factory.ts` | `/app/src/metadata/store/factory.ts` | `createMetadataStore` 加 postgres case；mongo/sqlite/postgres 环境变量三选一互斥；多实例共享 `pg.Pool`；`purgeInstance` = `DROP SCHEMA ... CASCADE` |
| `metadata-relation-id-insert.ts` | `/app/src/metadata/store/relation-id-insert.ts` | 关系表 id 冲突按 PG 唯一约束名（SQLSTATE 23505）识别 |
| `gateway-metadata-env.ts` | `/app/src/gateway/metadata-env.ts` | 环境变量 `TDAI_METADATA_POSTGRES_URI` 注入（不覆盖 YAML 已有配置） |

关键设计：

- **schema-per-instance**：每个 gateway 实例一个独立 schema `tdai_metadata_<instance_id>`
  （默认 `tdai_metadata_default`），DDL 由适配器首次使用时自动创建，无需手工执行；
  `purgeInstance` 即 `DROP SCHEMA ... CASCADE`。与存储面 9 张表同库共存。
- **配置**：`deploy/.env` 的 `METADATA_PG_CONNECTION_STRING`。留空/不配置 = 复用
  `PG_CONNECTION_STRING`（默认全 PG）；显式置为空字符串 = 回退容器 volume 内 SQLite。
  部署脚本以 `-e TDAI_METADATA_POSTGRES_URI` 注入容器。
- **admin key**：`init-admin` 创建的 admin 用户及其 `user_key`（`deploy/.admin-key`）
  现落在 PG 的 `meta_users` / `meta_user_keys` 表，容器 volume 重建后依然有效；反之
  `stop-all.sh --purge` 只清 volume，PG 侧需手动 DROP schema（见 §8.5）。
- **验证**：适配器对容器版 metadata 契约测试套件通过 46/46（与 SQLite 后端行为对齐）。

上游进展：元数据面 PG 化已提交上游 PR
[#1466](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1466)。

---

## 6. 数据库 Schema

> 存储面 9 张表由 `db/schema.sql` 创建；元数据面按实例自动建 schema（见 §6.4）。

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

### 6.4 元数据面 Schema（PG）

上表 9 张表属于存储面（memory plane）。元数据面切 PG 后（见 §5.4），适配器自动在
**同一个 `tdai_memory` 库**内按实例建 schema（默认 `tdai_metadata_default`，DDL 自动
执行），主要表：

| 表名 | 说明 |
|------|------|
| `meta_users` / `meta_user_keys` | 用户 + user_key 凭据（admin key 落在此） |
| `meta_teams` / `meta_team_members` | 团队 + 成员关系 |
| `meta_agents` / `meta_tasks` / `meta_task_agents` | Agent / 任务实体 + 任务-Agent 关系 |
| `meta_participation_logs` | 参与日志 |
| `meta_assets` / `meta_agent_fixed_assets` / `meta_asset_acl` | 资产 + Agent 绑定 + ACL |
| `meta_config_params` | 实例注册 + 配置参数 |

查看：`psql -d tdai_memory -c '\dn'` 列出 schema；
`SELECT username FROM tdai_metadata_default.meta_users;`。

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
| `/v3/skill/list` / `create` / `get` / `update` / `delete` / `versions` | POST | Skill 增删改查 + 版本管理（PG 后端已支持，见 §5.2） |
| `/v3/skill/search` | POST | Skill 检索（BM25 / 向量 / RRF 混合） |
| `/health` | GET | 健康检查 |

> 简单验证：`curl http://<server-ip>:8420/health`；
> 或运行 `scripts/test_pg_e2e.py` / `scripts/test_search.py`（配置见环境变量 `MEMORY_URL` / `MEMORY_ADMIN_KEY`）；
> 或运行 `scripts/main.py`（LangGraph 演示应用，TAM + Skill-Hub 双记忆，配置见环境变量
> `MEMORY_URL` / `MEMORY_ADMIN_KEY` / `SKILLHUB_URL` / `SKILLHUB_API_KEY` 等）；
> 纯 TAM 演示见 `example/`。

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

元数据面（schema 列表 + admin 用户）：

```bash
psql "postgres://postgres:<password>@<pg-host>:5432/tdai_memory" \
  -c '\dn' \
  -c 'SELECT username, status FROM tdai_metadata_default.meta_users;'
```

### 8.3 容器重建后补丁丢失？

如果手动 `docker rm` 容器，重新执行 `start-memory-core.sh` 会自动重新应用所有补丁。

### 8.4 切换回 SQLite

修改 `.env` 或 `start-memory-core.sh`：
1. YAML 配置中 `storeBackend: postgres` → `storeBackend: sqlite`
2. 删除 `STORE_MODE=postgres` 环境变量
3. 注释掉 `apply-pg-patches.sh` 调用
4. 元数据面回退 SQLite：`.env` 里显式设置 `METADATA_PG_CONNECTION_STRING=`（空字符串）

### 8.5 清理元数据面数据

`stop-all.sh --purge` 只删除 Docker volume——存储面 PG 表与元数据面 PG schema 均不受
影响。如需彻底清空元数据面：

```sql
DROP SCHEMA IF EXISTS tdai_metadata_default CASCADE;
```

删除后重启（`start-memory-core.sh`）会重建 schema，但 admin 用户需重新 init——记得同时
删掉 `deploy/.admin-key`，否则会拿到已失效的旧 key。

---

## 9. 已知限制

1. ~~**Skill wiring 跳过**~~ **已解决**：PG 后端此前不支持 SQLite 特有的 `getRawDb()` 接口而跳过 Skill 模块；现已通过 `pg-store.ts` 的 `getPgPool()` 逃生舱 + `pg-skill-store.ts` 实现完整对齐（见 §5.2）
2. **容器内补丁非持久化**: 通过 `docker commit` 自行固化的镜像可包含补丁，但用原始镜像每次重建容器都需要重新应用（`start-memory-core.sh` 会自动完成）
3. **jieba 分词**: FTS 使用 `tokenizeForFts` (jieba) 分词后存入 `message_segmented`，再生成 `tsvector`；查询时同样分词后用 `websearch_to_tsquery('simple', ...)`
4. **容器版元数据模块较旧**: 容器镜像内 metadata 模块早于上游 HEAD，`postgres-adapter.ts` 按容器版 `IMetadataStore` 接口适配——不含 `DuplicateUserKeyError`（user_key 撞车时返回原始唯一约束错误）与 `InstanceUpstreamConfig` 实例上游配置域（容器版无此接口）。上游合并 PR #1466 后的新镜像将以完整版覆盖

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
