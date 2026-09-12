# TDAI Memory Core — PostgreSQL Migration & Deployment Guide

English | [简体中文](README.md)

> **Open-source notice**: This repository is a collection of PostgreSQL storage-backend
> migration patches and deployment scripts for
> [TencentDB-Agent-Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory)
> (MIT licensed). Some files under `src/` and `patches/` are modified from upstream
> sources — see [LICENSE](LICENSE) and [NOTICE](NOTICE) for licensing and derivation details.

## 1. Overview

This guide describes how to migrate the TDAI Memory Core storage backend from SQLite
(sqlite-vec + FTS5) to PostgreSQL 16 + pgvector + tsvector.

### 1.1 Architecture

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

### 1.2 Components

| Component | Image / Version | Port | Purpose |
|-----------|-----------------|------|---------|
| Memory Core | `agentmemory/memory-core:latest` | 8420 | Memory gateway, PG backend |
| Memory Hub | `agentmemory/memory-hub:latest` | 18125 | Panel UI |
| Memory Proxy | `agentmemory/memory-proxy:latest` | 8096 | Claude Code proxy |
| Embedding | BGE-M3 (local) | 8121 | Vector embedding service |
| PostgreSQL | 16.13 (Debian) | 5432 | Database + pgvector |

### 1.3 Key endpoints

| Service | Address (replace with your actual deployment) |
|---------|------|
| Memory Core API | `http://<server-ip>:8420` |
| Panel UI | `http://<server-ip>:18125` |
| PostgreSQL | `postgres://postgres:<password>@<pg-host>:5432/tdai_memory` |
| Embedding | `http://<server-ip>:8121/v1/` |
| LLM (DashScope) | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| Admin Key | Auto-generated on first launch by `start-memory-core.sh`, saved to `deploy/.admin-key` |

---

## 2. Repository layout

```
TAM/
├── README.md / README_EN.md           ← This documentation (Chinese / English)
├── LICENSE / NOTICE                   ← MIT license + upstream derivation notice
├── src/                               ← Patched sources extracted from the container
│   ├── config.ts                      ← StoreBackend type + PostgresConfig + config parsing
│   ├── gateway/
│   │   └── server.ts                  ← STORE_MODE env var check
│   ├── utils/
│   │   └── manifest.ts                ← StoreConfigSnapshot + ManifestStoreInfo types
│   └── core/store/
│       ├── pg-store.ts                ← ★ NEW: PG storage implementation (IMemoryStore interface)
│       ├── factory.ts                 ← createStoreBundle adds postgres case
│       └── store-pool.ts              ← StoreMode + createPostgresStore + getStore branch
├── patches/                           ← Patch files + patching scripts
│   ├── pg-store.ts                    ← Same as src/core/store/pg-store.ts (for deployment)
│   ├── config.ts                      ← Same as src/config.ts (for deployment)
│   ├── factory.ts                     ← Same as src/core/store/factory.ts (for deployment)
│   ├── store-pool.ts                  ← Same as src/core/store/store-pool.ts (for deployment)
│   ├── manifest.ts                    ← Same as src/utils/manifest.ts (for deployment)
│   ├── server.ts                      ← Same as src/gateway/server.ts (for deployment)
│   ├── pg-store-original.ts           ← Original merged pg-store.ts (before bugfixes)
│   ├── patch-all.js                   ← Main patch script (config/factory/store-pool)
│   ├── fix-factory.js                 ← factory.ts postgres case insertion
│   ├── fix-config.js                  ← config.ts + manifest.ts fixes
│   ├── fix-manifest.js                ← manifest.ts type fixes
│   ├── fix-server.js                  ← server.ts STORE_MODE check
│   ├── fix-pg-import.cjs              ← Fix require("pg") → ES import
│   ├── fix-limit.cjs                  ← Fix LIMIT parameter typing (add ::int)
│   ├── fix-limit2.cjs                 ← Fix LIMIT/OFFSET in ++i patterns
│   ├── fix-params.cjs                 ← Fix buildIsoClause offset + ::vector cast
│   ├── fix-timestamp.cjs              ← Fix bigint timestamp → Number()
│   ├── fix-timestamp2.cjs             ← Fix timestamp in ?? 0 patterns
│   ├── fix-yaml.py                    ← YAML config repair script
│   └── create-db.js                   ← PG database creation script (reads PG_CONNECTION_STRING)
└── deploy/                            ← Deployment scripts
    ├── .env.example                   ← Environment variable template (copy to .env and fill in)
    ├── start-all.sh                   ← Start all services
    ├── start-memory-core.sh           ← ★ Start memory-core (modified for PG)
    ├── start-memory-hub.sh            ← Start panel UI
    ├── start-proxy.sh                 ← Start proxy
    ├── stop-all.sh                    ← Stop all services
    ├── apply-pg-patches.sh            ← ★ Auto-apply PG migration patches
    ├── _lib.sh                        ← Deployment helper functions
    └── verify.sh                      ← Deployment verification script
├── db/
│   └── schema.sql                     ← PG database DDL (9 tables + indexes)
└── scripts/                           ← Demo application
    ├── memory_client.py               ← Memory V2 API client
    ├── main.py                        ← LangGraph Chat Agent (config via environment variables)
    └── index.html                     ← Chat web UI
```

> Note: `.env`, `.admin-key`, and `tdai-gateway.yaml` contain local secrets and are not
> committed (see `.gitignore`); they are generated automatically by `start-memory-core.sh`
> on first deployment.

---

## 3. Prerequisites

### 3.1 PostgreSQL server

A PostgreSQL 16+ server with the following extensions:

```sql
-- Create the database
CREATE DATABASE tdai_memory;

-- Run after connecting to the tdai_memory database:
CREATE EXTENSION IF NOT EXISTS vector;      -- pgvector >= 0.8.0
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- pg_trgm >= 1.6
```

Verify:
```sql
SELECT extname, extversion FROM pg_extension WHERE extname IN ('vector', 'pg_trgm');
-- Expected: vector | 0.8.2, pg_trgm | 1.6
```

### 3.2 Docker

Docker must be installed on the deployment server. The Memory Core container reaches
PostgreSQL through a Docker network.

### 3.3 Embedding service

A BGE-M3 embedding service (1024 dimensions) exposing an OpenAI-compatible API.

---

## 4. Deployment

### 4.1 Upstream image + auto-patching (recommended)

```bash
# 1. Copy deployment files to the server
scp -r deploy/ root@<server>:/root/tdai-deploy/
scp -r patches/ root@<server>:/root/tdai-deploy/.memory-core-patches/
scp -r db/ root@<server>:/root/tdai-deploy/db/

# 2. Initialize the PG database (if not created yet)
psql -h <pg_host> -U postgres -d tdai_memory -f db/schema.sql
# Or use the patch script (reads the PG_CONNECTION_STRING env var):
# PG_CONNECTION_STRING="postgres://postgres:<password>@<pg-host>:5432/postgres" node patches/create-db.js

# 3. Configure environment variables
cp deploy/.env.example deploy/.env   # then edit:
#    - PG_CONNECTION_STRING : PG connection string (required)
#    - MEMORY_LLM_*         : LLM configuration
#    - EMBEDDING_*          : Embedding service configuration

# 4. Start (the script automatically: creates the container → sendDimensions hotfix
#    → applies PG patches → initializes the admin user)
cd /root/tdai-deploy && bash start-memory-core.sh
```

### 4.2 Configuration reference

#### Key .env variables

```bash
# Images
MEMORY_CORE_IMAGE=agentmemory/memory-core:latest
MEMORY_CORE_PORT=8420

# PostgreSQL (required)
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

# Data volume
MEMORY_CORE_VOLUME=tdai-memory-core-data
```

#### tdai-gateway.yaml PG section (auto-generated from .env by start-memory-core.sh)

```yaml
memory:
  storeBackend: postgres
  postgres:
    connectionString: "postgres://postgres:<password>@<pg-host>:5432/tdai_memory"
```

#### Environment variables

The container must run with `STORE_MODE=postgres`, injected automatically by
`start-memory-core.sh`.

---

## 5. Patch details

### 5.1 Modified source files (6)

| File | Container path | Change |
|------|----------------|--------|
| `pg-store.ts` | `/app/src/core/store/pg-store.ts` | **NEW**: PG storage implementation, ~670 lines, full `IMemoryStore` interface |
| `config.ts` | `/app/src/config.ts` | `StoreBackend` type adds `"postgres"`; new `PostgresConfig` interface; config parsing adds `postgres` field |
| `factory.ts` | `/app/src/core/store/factory.ts` | `createStoreBundle` switch adds `case "postgres"` |
| `store-pool.ts` | `/app/src/core/store/store-pool.ts` | `StoreMode` adds `"postgres"`; new `createPostgresStore()` method; `getStore` branch |
| `manifest.ts` | `/app/src/utils/manifest.ts` | `StoreConfigSnapshot` and `ManifestStoreInfo` types add postgres |
| `server.ts` | `/app/src/gateway/server.ts` | `STORE_MODE` env var check adds `"postgres"` |

### 5.2 Bug fix log

Bugs discovered after `pg-store.ts` was written, and their fixes:

| # | Bug | Cause | Fix | Script |
|---|-----|-------|-----|--------|
| 1 | `require is not defined` | tsx ESM mode does not support `require("pg")` | Changed to `import { Pool } from "pg"` | `fix-pg-import.cjs` |
| 2 | `LIMIT must be type bigint, not text` | PG parameterized LIMIT needs a type cast | Added `::int` to every LIMIT `$N` | `fix-limit.cjs` + `fix-limit2.cjs` |
| 3 | `could not determine data type of parameter $2` | `buildIsoClause(filter, 2)` skipped `$2`, leaving an empty parameter | Changed to `buildIsoClause(filter, 1)` | `fix-params.cjs` |
| 4 | Vector search type inference failure | `$1` type unknown in `embedding <=> $1` | Added `::vector` cast | `fix-params.cjs` |
| 5 | `Invalid time value` | PG `bigint` returned as string; `new Date("123")` is invalid | Convert with `Number(row.timestamp)` | `fix-timestamp.cjs` + `fix-timestamp2.cjs` |
| 6 | sendDimensions hotfix syntax error | `#` is a shell comment, not a TS comment | Changed to `//` | edit `start-memory-core.sh` |
| 7 | File encoding error | PowerShell downloaded files as UTF-16LE | Converted to UTF-8 with Python | `fix-encoding.py` (temporary) |

### 5.3 Patch application flow

`start-memory-core.sh` execution order:

```
1. Generate tdai-gateway.yaml (with storeBackend: postgres + connectionString)
2. docker run to create the container (with STORE_MODE=postgres)
3. Wait for container health
4. Apply sendDimensions hotfix (sed insertion + restart)
5. Call apply-pg-patches.sh:
   a. npm install pg --save
   b. docker cp the 6 patch files into the container
   c. docker restart
   d. Wait for health check
6. Initialize the admin user
7. Verify the admin key
```

---

## 6. Database schema

### 6.1 Tables

| Table | Purpose | Key columns |
|-------|---------|-------------|
| `l0_conversations` | L0 raw conversations | `record_id`, `message_text`, `embedding(vector)`, `message_tsv(tsvector)` |
| `l1_records` | L1 extracted memories | `record_id`, `content`, `embedding(vector)`, `content_tsv(tsvector)` |
| `memory_audit` | Audit log | `audit_id`, `record_id`, `action`, `updated_at_ms` |
| `embedding_meta` | Embedding metadata | `key`, `value` |
| `entity_teams` | Team entities | `team_id`, `name`, `user_ids_json` |
| `entity_users` | User entities | `user_id`, `name`, `team_ids_json` |
| `entity_agents` | Agent entities | `agent_id`, `team_id`, `prompt` |
| `entity_tasks` | Task entities | `task_id`, `team_id`, `status` |
| `entity_knowledge` | Knowledge entities | `knowledge_id`, `type`, `service_url` |

### 6.2 Indexes

- **FTS indexes**: `GIN` indexes on `message_tsv` / `content_tsv`
- **Vector indexes**: `IVFFlat` on `embedding` (cosine, lists=100)
- **B-tree indexes**: session_key, session_id, user_id+agent_id+session_id, timestamp, updated_time, etc.

### 6.3 Search mechanism

- **FTS search**: `tsvector` + `websearch_to_tsquery('simple', $query)` ranked by `ts_rank`
- **Vector search**: `embedding <=> $query_vector::vector` (cosine distance)
- **Hybrid search**: FTS + vector in parallel, results merged

---

## 7. API usage

### 7.1 Authentication

All API requests require these headers:

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

### 7.2 Core endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v2/conversation/add` | POST | Add a conversation (L0) |
| `/v2/conversation/search` | POST | Search conversations (FTS + vector) |
| `/v2/atomic/search` | POST | Search memories (L1, FTS + vector) |
| `/v2/core/read` | POST | Read persona |
| `/health` | GET | Health check |

> Quick verification: `curl http://<server-ip>:8420/health`;
> or run `scripts/main.py` (LangGraph demo app, configured via the `MEMORY_URL` /
> `MEMORY_ADMIN_KEY` environment variables).

---

## 8. Operations

### 8.1 Logs

```bash
docker logs -f tdai-memory-core
# Key log lines:
# [memory-tdai][pg] Initialized (dims=1024)
# backend=postgres, embedding=openai
# mode=postgres
```

### 8.2 Inspect PG data

```bash
# Run inside the container
docker exec -w /app tdai-memory-core node -e "
const{Pool}=require('pg');
const p=new Pool({connectionString:'postgres://postgres:<password>@<pg-host>:5432/tdai_memory'});
p.query('SELECT COUNT(*) FROM l0_conversations').then(r=>{console.log('L0:',r.rows[0].count);p.end()});
p.query('SELECT COUNT(*) FROM l1_records').then(r=>{console.log('L1:',r.rows[0].count);p.end()});
"
```

### 8.3 Patches lost after container rebuild?

If you manually `docker rm` the container, re-running `start-memory-core.sh` re-applies
all patches automatically.

### 8.4 Switching back to SQLite

Edit `.env` or `start-memory-core.sh`:
1. In the YAML config: `storeBackend: postgres` → `storeBackend: sqlite`
2. Remove the `STORE_MODE=postgres` environment variable
3. Comment out the `apply-pg-patches.sh` invocation

---

## 9. Known limitations

1. **Skill wiring skipped**: the log shows `Skill wiring skipped: vectorStore does not
   expose getRawDb()` — the PG backend does not support the SQLite-specific `getRawDb()`
   interface, limiting the Skill module (core memory functionality is unaffected).
2. **In-container patches are not persistent**: an image you bake yourself via
   `docker commit` can include the patches, but with the upstream image every container
   rebuild re-applies them (`start-memory-core.sh` does this automatically).
3. **jieba tokenization**: FTS stores `tokenizeForFts` (jieba) segmented text in
   `message_segmented`, then builds the `tsvector` from it; queries are segmented the
   same way before `websearch_to_tsquery('simple', ...)`.

---

## 10. Versions

| Component | Version |
|-----------|---------|
| Memory Core image | `agentmemory/memory-core:latest` (base) |
| PostgreSQL | 16.13 (Debian) |
| pgvector | 0.8.2 |
| pg_trgm | 1.6 |
| Node.js (in container) | v22.23.2 |
| tsx | ESM mode |
| pg npm package | latest |
| Doc date | 2026-08-27 (sanitized for open source 2026-09-12) |
