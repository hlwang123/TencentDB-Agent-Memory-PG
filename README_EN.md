# TencentDB-Agent-Memory-PG

Full-PostgreSQL migration & deployment toolkit for [TencentDB-Agent-Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory)

English | [简体中文](README.md)

> **Open-source notice**: this repository is a full-PostgreSQL migration & deployment
> toolkit for [TencentDB-Agent-Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory)
> (MIT licensed) — all patches target the TDAI Memory Core, the only component with a
> storage backend of its own (storage plane + Skill module + metadata plane); Memory
> Hub / Memory Proxy carry no storage and deploy unmodified. Together the three services
> form a **complete TencentDB-Agent-Memory stack, full-PG with no SQLite dependency**.
> Some files under `src/` and `patches/` are modified from upstream sources — see
> [LICENSE](LICENSE) and [NOTICE](NOTICE) for licensing and derivation details.
>
> **Upstream status**: the source-level integration has been submitted upstream as
> PR [#1387](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1387)
> (PostgreSQL storage backend + Skill module alignment), followed by
> PR [#1466](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1466)
> (PostgreSQL metadata backend — the last piece for a full-PG deployment with no SQLite
> dependency). Once both PRs are merged and released in an upstream image, `storeBackend:
> postgres` + `TDAI_METADATA_POSTGRES_URI` can be used natively without this patch chain;
> until then, the patch-based deployment described here remains the working approach.

## 1. Overview

This guide describes how to migrate TDAI Memory Core from SQLite to PostgreSQL 16 +
pgvector + tsvector in full, covering three planes:

1. **Storage plane** (L0/L1 memories + hybrid FTS/vector retrieval, §5.1)
2. **Skill module** (procedural memory: skill/experience storage and versioning, §5.2)
3. **Metadata plane** (v3 metadata: users/teams/agents/assets/ACLs, incl. the admin
   user_key, §5.4)

With all three on PostgreSQL you get a **full-PG deployment with no SQLite dependency** —
data is no longer locked inside the container volume: it becomes backupable,
highly available, and directly queryable via SQL.

The companion Memory Hub (Panel UI) and Memory Proxy (Claude Code proxy) carry no storage
of their own and deploy unmodified — so PG-enabling the single memory-core component yields
a **complete full-PG TencentDB-Agent-Memory stack** (the deployment scripts in this repo
bring up all three services, see §4).

### 1.1 Architecture

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

### 1.2 Components

| Component | Image / Version | Port | Purpose |
|-----------|-----------------|------|---------|
| Memory Core | `agentmemory/memory-core:latest` | 8420 | Memory gateway, full-PG backend (storage + metadata) |
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
├── docs/
│   └── tam-pg-support.md              ← TAM feature overview & PostgreSQL support notes (Chinese)
├── src/                               ← Patched sources extracted from the container
│   ├── config.ts                      ← StoreBackend type + PostgresConfig + config parsing
│   ├── gateway/
│   │   ├── server.ts                  ← STORE_MODE env var check
│   │   └── metadata-env.ts            ← ★ NEW: TDAI_METADATA_POSTGRES_URI env injection
│   ├── utils/
│   │   └── manifest.ts                ← StoreConfigSnapshot + ManifestStoreInfo types
│   ├── core/
│   │   ├── tdai-core.ts               ← ★ MODIFIED: Skill wiring adds getPgPool() branch
│   │   ├── skill/
│   │   │   └── pg-skill-store.ts      ← ★ NEW: Skill data-access layer, PG implementation
│   │   └── store/
│   │       ├── pg-store.ts            ← ★ NEW: PG storage (IMemoryStore + getPgPool() escape hatch)
│   │       ├── factory.ts             ← createStoreBundle adds postgres case
│   │       └── store-pool.ts          ← StoreMode + createPostgresStore + getStore branch
│   ├── metadata/                      ← ★ NEW: metadata plane (v3 metadata) PG backend
│   │   └── store/
│   │       ├── postgres-adapter.ts    ← ★ NEW: PostgresMetadataStore (schema-per-instance)
│   │       ├── interface.ts           ← MetadataBackend type adds "postgres"
│   │       ├── db-name.ts             ← resolvePostgresSchemaName (63-byte truncation)
│   │       ├── factory.ts             ← createMetadataStore postgres case + 3-way exclusivity
│   │       └── relation-id-insert.ts  ← PG unique-violation (23505) detection via pkey names
├── patches/                           ← Patch files + patching scripts
│   ├── pg-store.ts                    ← Same as src/core/store/pg-store.ts (for deployment)
│   ├── config.ts                      ← Same as src/config.ts (for deployment)
│   ├── factory.ts                     ← Same as src/core/store/factory.ts (for deployment)
│   ├── store-pool.ts                  ← Same as src/core/store/store-pool.ts (for deployment)
│   ├── manifest.ts                    ← Same as src/utils/manifest.ts (for deployment)
│   ├── server.ts                      ← Same as src/gateway/server.ts (for deployment)
│   ├── tdai-core.ts                   ← Same as src/core/tdai-core.ts (for deployment)
│   ├── pg-skill-store.ts              ← Same as src/core/skill/pg-skill-store.ts (for deployment)
│   ├── pg-metadata-store.ts           ← Same as src/metadata/store/postgres-adapter.ts (for deployment)
│   ├── metadata-interface.ts          ← Same as src/metadata/store/interface.ts (for deployment)
│   ├── metadata-db-name.ts            ← Same as src/metadata/store/db-name.ts (for deployment)
│   ├── metadata-factory.ts            ← Same as src/metadata/store/factory.ts (for deployment)
│   ├── metadata-relation-id-insert.ts ← Same as src/metadata/store/relation-id-insert.ts (for deployment)
│   ├── gateway-metadata-env.ts        ← Same as src/gateway/metadata-env.ts (for deployment)
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
├── deploy/                            ← Deployment scripts
│   ├── .env.example                   ← Environment variable template (copy to .env and fill in)
│   ├── start-all.sh                   ← Start all services
│   ├── start-memory-core.sh           ← ★ Start memory-core (modified for PG)
│   ├── start-memory-hub.sh            ← Start panel UI
│   ├── start-proxy.sh                 ← Start proxy
│   ├── stop-all.sh                    ← Stop all services
│   ├── apply-pg-patches.sh            ← ★ Auto-apply PG migration patches (14 files)
│   ├── _lib.sh                        ← Deployment helper functions
│   └── verify.sh                      ← Deployment verification script
├── db/
│   └── schema.sql                     ← PG database DDL (9 tables + indexes)
├── skill-align/                       ← ★ Skill module PG-alignment verification suite (E2E/smoke scripts)
├── example/                           ← TAM memory Agent demo app (FastAPI + LangGraph + Web UI)
└── scripts/                           ← Test/demo scripts
    ├── memory_client.py               ← Memory V2 API client
    ├── main.py                        ← LangGraph Chat Agent (TAM + Skill-Hub dual memory)
    ├── index.html                     ← Chat web UI
    ├── test_pg_e2e.py                 ← PG end-to-end test (config via environment variables)
    └── test_search.py                 ← Search test (config via environment variables)
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

> Note: the metadata plane automatically creates per-instance schemas (`tdai_metadata_*`)
> inside the `tdai_memory` database (see §5.4), so the connecting account needs CREATE
> privilege on that database (satisfied by default for the database owner).

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

# Metadata plane (v3 metadata) PG backend
# Unset/empty = reuse PG_CONNECTION_STRING above (full-PG default);
# explicitly set to an empty string to fall back to SQLite in the container volume.
# METADATA_PG_CONNECTION_STRING=
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

> Note: the 14 patches below target the source layout inside the current upstream
> container image (§5.1 storage plane: 8 files + §5.4 metadata plane: 6 files).
> Upstream PR [#1387](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1387)
> places the new storage-plane files at
> `src/core/store/postgres/{memory-store,skill-store}.ts` following the upstream
> directory convention; the metadata-plane PG backend has been submitted as upstream
> PR [#1466](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1466)
> (`src/metadata/store/postgres-adapter.ts`). All functionally equivalent.

### 5.1 Storage plane: modified source files (8)

| File | Container path | Change |
|------|----------------|--------|
| `pg-store.ts` | `/app/src/core/store/pg-store.ts` | **NEW**: PG storage implementation, ~670 lines, full `IMemoryStore` interface; adds `getPgPool()` escape hatch (exposes the pool + dimensions for the Skill module) |
| `config.ts` | `/app/src/config.ts` | `StoreBackend` type adds `"postgres"`; new `PostgresConfig` interface; config parsing adds `postgres` field |
| `factory.ts` | `/app/src/core/store/factory.ts` | `createStoreBundle` switch adds `case "postgres"` |
| `store-pool.ts` | `/app/src/core/store/store-pool.ts` | `StoreMode` adds `"postgres"`; new `createPostgresStore()` method; `getStore` branch |
| `manifest.ts` | `/app/src/utils/manifest.ts` | `StoreConfigSnapshot` and `ManifestStoreInfo` types add postgres |
| `server.ts` | `/app/src/gateway/server.ts` | `STORE_MODE` env var check adds `"postgres"` |
| `tdai-core.ts` | `/app/src/core/tdai-core.ts` | **MODIFIED**: Skill wiring branch — SQLite uses `getRawDb()`, PostgreSQL uses `getPgPool()` to construct `PgSkillStore` (role-equivalent to SQLite) |
| `pg-skill-store.ts` | `/app/src/core/skill/pg-skill-store.ts` | **NEW**: PostgreSQL implementation of the Skill data-access layer, semantically 1:1 aligned with `SqliteSkillStore` |

### 5.2 Skill module PG alignment (pg-align)

The Skill module (procedural memory: storing/searching/versioning skills and experiences,
plus conversation-driven extraction) originally supported SQLite only — core initialization
obtains the underlying DB handle via `VectorStore.getRawDb()`. The PG backend therefore used
to skip Skill wiring (log line `Skill wiring skipped`).

The alignment approach (no intrusion into upstream interfaces):

| Aspect | SQLite version | PG version (pg-skill-store.ts) |
|--------|----------------|-------------------------------|
| Escape hatch | `getRawDb()` → `DatabaseSync` | `PgMemoryStore.getPgPool()` → shares the same `pg.Pool` + dimensions |
| Full-text search | FTS5 | `skills.fts_segmented` (jieba-presegmented) + `fts_tsv` generated column + GIN (auto-maintained on row updates) |
| Vector search | vec0 virtual table | separate table `skill_vec(skill_id PK, embedding vector(dim))` + IVFFlat cosine; embedding / hybrid (RRF) retrieval paths are **wired up** (mirroring the server-side embedding semantics of the TCVDB cloud backend: `appendVersion` re-embeds the head asynchronously on write, queries embed on the fly, and existing rows are backfilled at startup) — available when an embedding provider is configured (including cross-language CN/EN semantic search), otherwise falls back to bm25 (same as the SQLite/MongoDB backends) |
| Write serialization | `BEGIN IMMEDIATE` (whole-DB) | transaction-scoped advisory lock (`pg_advisory_xact_lock(hashtext(skill_id))`), serialized per skill_id |
| Timestamps | INTEGER ms | BIGINT (`Date.now()` exceeds int4); converted back with `Number()` |
| DDL | synchronous table creation | async DDL in `init()`; methods `await readyPromise` so requests queue until DDL completes |

Tables are created automatically by `PgSkillStore.init()` (`skills` — multi-version rows with an
`is_head` flag — plus the `skill_vec` vector table); no manual DDL required. The success log line
on startup:

```
[memory-tdai] [pg-align] Skill store backend: PgSkillStore (dimensions=1024, embedding=on)
```

(`embedding=on` means an embedding function was injected; without an embedding provider it reads
`embedding=off` and search falls back to bm25. With a provider configured, existing skills without
vectors are also backfilled automatically at startup:
`[pg-skill-store] backfilled embeddings for N skill(s)`.)

End-to-end verification scripts live in `skill-align/` (`skill-e2e.sh`: CRUD/versioning/Chinese+
English BM25 search/duplicate-name conflict/physical delete + PG table checks;
`skill-extract-e2e.sh`: conversation → LLM skill extraction).

### 5.3 Patch application flow

`start-memory-core.sh` execution order:

```
1. Generate tdai-gateway.yaml (with storeBackend: postgres + connectionString)
2. docker run to create the container (with STORE_MODE=postgres + TDAI_METADATA_POSTGRES_URI)
3. Wait for container health
4. Apply sendDimensions hotfix (sed insertion + restart)
5. Call apply-pg-patches.sh:
   a. npm install pg --save
   b. docker cp the 14 patch files into the container (8 storage-plane + 6 metadata-plane, see §5.4)
   c. docker restart
   d. Wait for health check
6. Initialize the admin user
7. Verify the admin key
```

### 5.4 Metadata plane PG backend (pg-metadata, 6 files)

The v3 metadata plane (users/teams/agents/tasks/assets/ACLs and their relations, including
the admin user_key and instance registration) originally had only SQLite / MongoDB backends —
even with the storage plane on PG, metadata still lived in a SQLite file inside the container
volume. This patch set adds `PostgresMetadataStore` (implementing the container-version
`IMetadataStore` interface in full), enabling a **full-PG deployment with no SQLite
dependency**.

| File | Container path | Change |
|------|----------------|--------|
| `pg-metadata-store.ts` | `/app/src/metadata/store/postgres-adapter.ts` | **NEW**: `PostgresMetadataStore`; automatic SQL dialect conversion (`?`→`$n`, schema-prefix injection for `meta_*` tables, `INSERT OR IGNORE`→`ON CONFLICT DO NOTHING`, bigint COUNT→Number) |
| `metadata-interface.ts` | `/app/src/metadata/store/interface.ts` | `MetadataBackend` type adds `"postgres"` |
| `metadata-db-name.ts` | `/app/src/metadata/store/db-name.ts` | New `resolvePostgresSchemaName()` (instance-id sanitizing + PG 63-byte identifier truncation) |
| `metadata-factory.ts` | `/app/src/metadata/store/factory.ts` | `createMetadataStore` postgres case; mongo/sqlite/postgres env vars are mutually exclusive; shared `pg.Pool`; `purgeInstance` = `DROP SCHEMA ... CASCADE` |
| `metadata-relation-id-insert.ts` | `/app/src/metadata/store/relation-id-insert.ts` | Relation-table id collisions detected via PG unique-constraint names (SQLSTATE 23505) |
| `gateway-metadata-env.ts` | `/app/src/gateway/metadata-env.ts` | `TDAI_METADATA_POSTGRES_URI` env injection (does not override existing YAML config) |

Key design points:

- **Schema-per-instance**: each gateway instance gets its own schema
  `tdai_metadata_<instance_id>` (default `tdai_metadata_default`). DDL is created
  automatically by the adapter on first use — no manual steps; `purgeInstance` is simply
  `DROP SCHEMA ... CASCADE`. Coexists with the 9 storage-plane tables in the same database.
- **Configuration**: `METADATA_PG_CONNECTION_STRING` in `deploy/.env`. Unset/empty = reuse
  `PG_CONNECTION_STRING` (full-PG by default); explicitly set to an empty string = fall back
  to SQLite inside the container volume. The deployment script injects it into the container
  as `-e TDAI_METADATA_POSTGRES_URI`.
- **Admin key**: the admin user created by `init-admin` and its `user_key`
  (`deploy/.admin-key`) now live in the PG tables `meta_users` / `meta_user_keys`, surviving
  container-volume rebuilds; conversely `stop-all.sh --purge` only clears the volume — the
  PG-side schema must be dropped manually (see §8.5).
- **Validation**: the adapter passes 46/46 tests of the container-version metadata contract
  suite (behavior-aligned with the SQLite backend).

Upstream status: the metadata-plane PG backend has been submitted as upstream PR
[#1466](https://github.com/TencentCloud/TencentDB-Agent-Memory/pull/1466).

---

## 6. Database schema

> The 9 storage-plane tables are created by `db/schema.sql`; metadata-plane schemas are
> created automatically per instance (see §6.4).

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

### 6.4 Metadata plane schema (PG)

The 9 tables above belong to the storage plane (memory plane). With the metadata plane on PG
(see §5.4), the adapter automatically creates per-instance schemas in the **same `tdai_memory`
database** (default `tdai_metadata_default`, DDL executed automatically). Main tables:

| Table | Purpose |
|-------|---------|
| `meta_users` / `meta_user_keys` | Users + user_key credentials (the admin key lives here) |
| `meta_teams` / `meta_team_members` | Teams + membership relations |
| `meta_agents` / `meta_tasks` / `meta_task_agents` | Agent / task entities + task-agent relations |
| `meta_participation_logs` | Participation logs |
| `meta_assets` / `meta_agent_fixed_assets` / `meta_asset_acl` | Assets + agent bindings + ACLs |
| `meta_config_params` | Instance registration + config params |

Inspect with `psql -d tdai_memory -c '\dn'` (list schemas) and
`SELECT username FROM tdai_metadata_default.meta_users;`.

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
| `/v3/skill/list` / `create` / `get` / `update` / `delete` / `versions` | POST | Skill CRUD + versioning (supported on PG, see §5.2) |
| `/v3/skill/search` | POST | Skill search (BM25 / vector / RRF hybrid) |
| `/health` | GET | Health check |

> Quick verification: `curl http://<server-ip>:8420/health`;
> run `scripts/test_pg_e2e.py` / `scripts/test_search.py` (configured via the `MEMORY_URL` /
> `MEMORY_ADMIN_KEY` environment variables);
> or run `scripts/main.py` (LangGraph demo app with TAM + Skill-Hub dual memory, configured via
> `MEMORY_URL` / `MEMORY_ADMIN_KEY` / `SKILLHUB_URL` / `SKILLHUB_API_KEY`, etc.).
> For a TAM-only demo see `example/`.

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

Metadata plane (list schemas + admin user):

```bash
psql "postgres://postgres:<password>@<pg-host>:5432/tdai_memory" \
  -c '\dn' \
  -c 'SELECT username, status FROM tdai_metadata_default.meta_users;'
```

### 8.3 Patches lost after container rebuild?

If you manually `docker rm` the container, re-running `start-memory-core.sh` re-applies
all patches automatically.

### 8.4 Switching back to SQLite

Edit `.env` or `start-memory-core.sh`:
1. In the YAML config: `storeBackend: postgres` → `storeBackend: sqlite`
2. Remove the `STORE_MODE=postgres` environment variable
3. Comment out the `apply-pg-patches.sh` invocation
4. Metadata plane fallback to SQLite: explicitly set `METADATA_PG_CONNECTION_STRING=` (empty string) in `.env`

### 8.5 Purging metadata-plane data

`stop-all.sh --purge` deletes the Docker volume and the local `deploy/.admin-key`, but does
**not** touch the PG-side storage-plane tables or the metadata-plane schema. With the
metadata plane on PG, after `--purge` you **must also drop the schema** — otherwise the
next start fails to recover: init-admin returns 409 because the old admin still exists, and
the freshly generated key never takes effect:

```sql
DROP SCHEMA IF EXISTS tdai_metadata_default CASCADE;
```

If you only want to wipe the metadata plane (leaving the volume / admin key alone), running
the DROP above by itself is fine: re-run `start-memory-core.sh` afterwards and the schema is
recreated automatically while init-admin rebuilds the admin user using the existing
`.admin-key` (same key — it self-heals).

---

## 9. Known limitations

1. ~~**Skill wiring skipped**~~ **Resolved**: the PG backend used to skip the Skill module
   because it lacked the SQLite-specific `getRawDb()` interface; full alignment is now provided
   via the `getPgPool()` escape hatch in `pg-store.ts` + `pg-skill-store.ts` (see §5.2).
2. **In-container patches are not persistent**: an image you bake yourself via
   `docker commit` can include the patches, but with the upstream image every container
   rebuild re-applies them (`start-memory-core.sh` does this automatically).
3. **jieba tokenization**: FTS stores `tokenizeForFts` (jieba) segmented text in
   `message_segmented`, then builds the `tsvector` from it; queries are segmented the
   same way before `websearch_to_tsquery('simple', ...)`.
4. **Container metadata module is older than upstream HEAD**: the metadata module inside
   the container image predates upstream HEAD, so `postgres-adapter.ts` is adapted to the
   container-version `IMetadataStore` interface — it does not include `DuplicateUserKeyError`
   (user_key collisions surface the raw unique-constraint error) or the
   `InstanceUpstreamConfig` domain (not present in the container version). A newer upstream
   image after PR #1466 merges will ship the full version.

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
