# skill-align — Skill 模块 PostgreSQL 后端对齐验证套件

TAM 的 Skill 模块（程序性记忆：技能/经验的存储、检索、版本管理、对话提取）原本仅支持
SQLite（`VectorStore.getRawDb()` 逃生舱）。本套件配合 `patches/pg-skill-store.ts` +
`patches/tdai-core.ts`，使 `storeBackend=postgres` 时 Skill 模块通过
`PgMemoryStore.getPgPool()` 复用同一 PG 连接池，语义与 SQLite 版 1:1 对齐。

部署方式见仓库根目录 `README.md` §5（`deploy/apply-pg-patches.sh` 已包含 skill 两个补丁）。

## 环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `MEMORY_ADMIN_KEY` | 是 | memory-core admin key（部署机 `deploy/.admin-key`） |
| `PG_CONNECTION_STRING` | PG 检查步骤需要 | `postgres://user:pass@host:5432/tdai_memory` |
| `MEMORY_URL` | 否 | 默认 `http://localhost:8420` |
| `MEMORY_TEAM_ID` | 否 | 默认 `team-demo0000001` |
| `SKILL_E2E_AGENT_ID` | 否 | extract/verify 脚本使用的 agent，默认 `agt-e2etest000001` |

## 脚本清单（在部署机上运行）

| 脚本 | 用途 |
|------|------|
| `skill-e2e.sh` | `/v3/skill/*` 全链路 E2E：list → create → get → search(bm25) → update → versions → 重复名 → delete → PG 表结构校验 |
| `skill-extract-e2e.sh` | 对话提取链路：写入含工具调用的对话 → force-archive 触发 LLM 提取 → 轮询 skill 生成 |
| `verify-extract.sh` | 验证提取出的 skill 可被中英文查询检索到 |
| `final-smoke.sh` | 部署后冒烟：health + skill list + L0/L1/skills 计数 + 会话检索 |
| `live-check.sh` | 运行态快速检查（health / skill list / search / PG 行数） |
| `query-agents.sh` | 列出 PG public 表并抽样 agent/entity/asset 表 |
| `inspect-meta.sh` | 检查容器内 sqlite 残留与 metadata store 日志 |
| `test-userkey.sh` | `/v3/meta/auth/verify` 鉴权检查 |

## 典型流程

```bash
export MEMORY_ADMIN_KEY=<admin-key>
export PG_CONNECTION_STRING=postgres://postgres:<password>@<pg-host>:5432/tdai_memory

bash skill-e2e.sh            # 1. CRUD/检索/版本 全链路
bash skill-extract-e2e.sh    # 2. 对话 → LLM 提取 skill
bash verify-extract.sh       # 3. 检索验证
bash final-smoke.sh          # 4. 冒烟收尾
```

## 预期关键日志（memory-core 启动时）

```
[pg-align] Skill store backend: PgSkillStore (dimensions=1024)
```

若看到 `Skill wiring skipped: ...`，说明补丁未生效（检查 `apply-pg-patches.sh` 是否
拷贝了 `pg-skill-store.ts` 与 `tdai-core.ts`）。
