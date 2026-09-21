# TAM（TencentDB-Agent-Memory）特性介绍与 PostgreSQL 支持说明

> 结合官方说明（npm 包描述、源码文档）与本项目实际部署验证整理。
> https://github.com/hlwang123/TencentDB-Agent-Memory-PG

---

## 1. TAM 是什么

TAM（TencentDB-Agent-Memory，npm 包 `@tencentdb-agent-memory/memory-tencentdb-v2`）是腾讯开源的 **Agent 记忆系统**，官方定位：

> "Four-layer local memory system plugin — auto-captures, structures, and profiles conversational knowledge using local LLM + vector search (L0→L1→L2→L3 pipeline)"
> （四层本地记忆系统：自动捕获、结构化、画像化对话知识）

它解决的核心问题是：**大模型本身没有长期记忆**。TAM 让 Agent 具备跨会话的"记事"能力——用户说过什么、喜欢什么、做过什么，都能在之后的对话中自动想起。

### 1.1 整体架构

```
Agent 应用（OpenClaw / 自研 Agent / Claude Code 等）
     │  HTTP API（/v2、/v3）
     ▼
Memory Gateway（memory-core，端口 8420）──── LLM（记忆提取/画像生成）
     │                                    ──── Embedding（向量化，如 BGE-M3）
     ▼
存储后端（SQLite / TCVDB / PostgreSQL）
```

配套组件：

| 组件 | 镜像 | 端口 | 作用 |
|------|------|------|------|
| Memory Core | `agentmemory/memory-core` | 8420 | 记忆网关：API、提取流水线、检索 |
| Memory Hub | `agentmemory/memory-hub` | 18125 | Panel UI 管理界面 |
| Memory Proxy | `agentmemory/memory-proxy` | 8096 | Claude Code 代理接入 |

### 1.2 官方生态

- **OpenClaw 插件**：官方提供 `memory-tencentdb-client` 插件，通过 hooks 自动捕获对话（`agent_end` → L0）、构建提示词前自动召回（`before_prompt_build` → 检索注入）
- **TypeScript SDK**：`@tencentdb-agent-memory/memory-sdk-ts-v2`（npm 公开包）
- **适配器模板**：官方文档明确支持将任意 Agent 框架接入（本项目即按此模式自研了 Python Agent，见 `example/`）

---

## 2. 核心特性：L0→L1→L2→L3 四层记忆流水线

官方源码（index.ts）对四层的定义：

| 层 | 名称 | 内容 | 生成方式 |
|----|------|------|----------|
| **L0** | 对话记录 | 原始对话逐轮存档（who/when/said what） | 实时自动写入，无 LLM |
| **L1** | 结构化记忆 | 从 L0 提取的事实原子（"用户喜欢爬山"、"用户 9 月要爬泰山"） | LLM 异步提取 + 去重合并 |
| **L2** | 场景块 | 按主题组织的知识文件（项目文档、笔记） | LLM 场景提取 |
| **L3** | 用户画像 | persona.md 自然语言画像（身份/偏好/习惯） | LLM 定期汇总合成 |

流水线特点：

1. **全自动**：Agent 侧只需调 `addConversation` 写 L0，L1/L2/L3 由后台异步完成（空闲触发，无需人工干预）
2. **混合检索**：全文检索（FTS）+ 向量语义检索（cosine）并行、合并排序——关键词命中和语义相似互补
3. **三级隔离**：`instanceId`（服务实例）→ `teamId / agentId / userId`（团队/Agent/用户），多租户数据天然隔离
4. **可配置保留**：`l0l1RetentionDays` 控制记忆过期（默认永不过期）
5. **LLM 无关**：兼容 OpenAI 协议端点（DashScope / vLLM / 本地模型均可），Embedding 同样可插拔（BGE-M3 等）

### 2.1 API 面（v2/v3）

| 类别 | 接口 |
|------|------|
| 对话 | `conversation/add`、`conversation/search`、`conversation/count`、`conversation/delete`、`conversation/query` |
| 记忆 | `atomic/search`、`atomic/update`、`atomic/delete`、`atomic/count` |
| 画像 | `core/read`、`core/write` |
| 场景 | `scenario/ls`、`scenario/read`、`scenario/write`、`scenario/rm` |
| Skill | `skill/list`、`skill/get`、`skill/create`、`skill/update`、`skill/delete`、`skill/search`、`skill/versions` |
| 文件 | `cos/secret`（COS STS 临时凭证读取记忆文件） |

---

## 3. 优势总结

| 优势 | 说明 |
|------|------|
| **开箱即用** | 单容器启动即得完整记忆服务（API + 提取流水线 + 管理 UI），Agent 侧零改造（hooks 自动接入） |
| **分层降噪** | 原始对话（L0）与提炼事实（L1）分离，召回时注入的是压缩后的事实而非全部聊天记录，节省 token |
| **混合检索** | FTS + 向量双路，兼顾精确关键词（人名、日期、代码标识符）与语义模糊匹配 |
| **画像驱动** | L3 persona 让 Agent"开口就认识用户"，无需用户重复自我介绍 |
| **多租户隔离** | instance/team/agent/user 四级 ID 隔离，适合 SaaS 或多 Agent 共部署 |
| **模型可插拔** | LLM 与 Embedding 均走 OpenAI 兼容协议，可全内网部署（如内网 vLLM + BGE-M3） |
| **生态完整** | npm SDK、OpenClaw 插件、Panel UI、Claude Code 代理，均有官方维护 |

---

## 4. 目前支持的数据库

### 4.1 官方支持（源码 config.ts：`storeBackend`）

| 后端 | 模式 | 实现 | 适用场景 |
|------|------|------|----------|
| **SQLite**（默认） | standalone | sqlite-vec 向量 + FTS5 全文，每个 instanceId 一个本地文件 | 单机、本地开发、个人助手 |
| **TCVDB**（腾讯云向量数据库） | service | 远程向量库连接 + BM25 稀疏编码（`@tencentdb-agent-memory/tcvdb-text`），支持服务端稠密索引 | 腾讯云上生产部署、多实例共享 |

源码注释（store-pool.ts）：
> 双模式支持：standalone 使用 SQLite 本地存储（每个 instanceId 一个 SQLite 文件）；service 使用 TCVDB 向量数据库（每个 instanceId 一个远程 VDB 连接）

### 4.2 本项目扩展：PostgreSQL

我们在源码层实现了完整的 PG 存储后端（`pg-store.ts`，~670 行，实现全部 `IMemoryStore` 接口），并通过补丁链集成进官方镜像运行：

| 项 | 值 |
|----|----|
| 数据库 | PostgreSQL 16.13 + pgvector 0.8.2 + pg_trgm 1.6 |
| 表结构 | 9 张表（l0_conversations、l1_records、memory_audit、embedding_meta、entity_teams/users/agents/tasks/knowledge） |
| 全文检索 | tsvector + GIN 索引（jieba 分词 + `websearch_to_tsquery`） |
| 向量检索 | pgvector IVFFlat（cosine，lists=100） |
| 配置方式 | `storeBackend: postgres` + `connectionString`（与官方 tcvdb 配置同构） |

在 PG 存储后端之上，本项目进一步实现了 **Skill 模块的 PG 对齐**（`pg-skill-store.ts`，
见根目录 `README.md` §5 与 `skill-align/`），使 Skill（程序性记忆）也完整运行在
PostgreSQL 上。

---

## 5. 增加 PostgreSQL 的必要性

### 5.1 SQLite 的局限（官方默认后端）

| 局限 | 影响 |
|------|------|
| **单文件、单写者** | 写并发受限（WAL 模式下仍串行写），多 Agent 高频写入时成瓶颈 |
| **无法网络访问** | 数据库文件锁死在 memory-core 容器卷内，其他系统（BI、审计、管理工具）无法直连分析 |
| **无高可用** | 无主从、无 PITR、无集群方案；容器误删即数据丢失风险，备份只能靠拷文件 |
| **per-instance 碎片化** | 每个 instanceId 一个独立文件，跨实例聚合查询不可能 |
| **运维生态弱** | 无法用 SQL 做数据治理、权限控制、监控集成 |

### 5.2 TCVDB 的局限（官方云后端）

| 局限 | 影响 |
|------|------|
| **强依赖腾讯云** | 内网/专有云环境无法访问公网向量数据库服务 |
| **商业付费** | 按实例/容量计费，自建内网场景成本与合规双重障碍 |
| **厂商锁定** | 私有 API，迁出成本高 |
| **纯向量库** | 实体表（team/user/agent/knowledge）、审计日志等结构化数据仍需另配关系库，双存储运维 |

### 5.3 PostgreSQL 的适配价值

1. **内网自主可控**：开源、可部署在内网任意服务器，满足数据不出域要求
2. **一库三能**：关系表（实体/审计）+ pgvector 向量检索 + tsvector 全文检索，单一数据库覆盖 TAM 全部存储需求，无需外挂向量库
3. **企业级能力**：MVCC 高并发读写、主从复制/PITR 备份、权限体系、成熟的 DBA 运维工具链（psql/pg_dump/监控生态）
4. **网络原生**：集中式部署，多实例、多应用共享一个记忆库；管理侧可直接 SQL 查询审计
5. **行业惯例**：pgvector 已是 AI 应用存储的事实标准（LangChain/LlamaIndex 一等支持），团队熟悉度高
6. **平滑迁移**：`storeBackend` 配置一行切换，API 层零变化（我们的验证：API 兼容、混合检索正常、L0→L1 流水线正常）

### 5.4 实测验证结论（本项目部署）

- **数据规模**：数百条 L0 对话（含带 BGE-M3 向量的历史导入）、L1 提取正常入库
- **功能**：混合检索（FTS+向量）、persona 读写、场景块、记忆增删改查全部通过 E2E 测试
- **Skill 模块**：`skill-e2e.sh` / `skill-extract-e2e.sh` 全链路通过——CRUD、版本管理、中英文 BM25 检索、对话提取生均正常
- **元数据面**：v3 metadata 已切 PG（每实例一个 `tdai_metadata_*` schema，DDL 自动创建），admin user_key 落库、容器 volume 重建后依然有效；容器版契约测试 46/46 通过——**全 PG 部署、无 SQLite 残留**
- **多轮记忆**：Agent 跨轮正确回忆用户姓名/职业/爱好（L1 提取 ~10 分钟后生效）
- **已知限制**：容器重建需重放补丁（`start-memory-core.sh` 自动完成）

---

## 6. 参考资料

| 资料 | 位置 |
|------|------|
| npm 包（官方描述/SDK） | `@tencentdb-agent-memory/memory-tencentdb-v2`、`memory-sdk-ts-v2` |
| 官方源码 | 容器内 `/app/src/`（上游 GitHub 仓库） |
| 本仓库补丁 | `patches/`（14 个文件：pg-store / pg-skill-store / pg-metadata-store 等） |
| 部署文档 | 仓库根目录 `README.md` |
