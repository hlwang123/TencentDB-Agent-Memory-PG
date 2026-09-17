# TAM 记忆 Agent 示例（example）

基于 FastAPI + LangGraph 的测试 Agent，演示 TencentDB-Agent-Memory（TAM）的完整用法：
**TAM 语义记忆**（persona / L1 事实 / 对话检索），并带 Web 页面。

## 1. 文件结构

```
example/
├── main.py            # Agent 主程序（FastAPI + LangGraph ReAct Agent + Web 服务）
├── memory_client.py   # TAM Memory V2 API 客户端（persona 读写 / 记忆搜索 / 对话记录）
├── mcp_client.py      # MCP 工具客户端（知识库工具调用）
├── static/index.html  # Web 页面（登录 / 对话 / 记忆面板）
└── README.md          # 本说明
```

## 2. 架构

```
浏览器 ── http://localhost:8501 ──► main.py (LangGraph Agent)
                                      │
                                      ├─ LLM      ──► OpenAI 兼容端点（如 qwen3.8-27b）
                                      ├─ 记忆工具  ──► TAM memory-core:8420（user_persona /
                                      │               memory_search / conversation_search）
                                      └─ 知识工具  ──► MCP :8432（知识库检索）
```

每次对话 main.py 自动完成：
1. 读取用户 persona（`/v2/core/read`）注入系统提示
2. Agent 对话，可调用记忆/知识工具
3. 会话后 TAM L0 记录（→ L1/L2/L3 流水线自动提取）

## 3. 环境要求

- Python 3.10+
- 已部署的 TAM 服务（见仓库根目录 `README.md`）
- LLM 端点（OpenAI 兼容）

安装依赖：

```bash
pip install fastapi uvicorn httpx langchain-core langchain-openai langgraph mcp
# 参考版本：langchain-core 1.6.0 / langchain-openai 1.6.0 / langgraph 1.2.11
```

## 4. 配置

配置全部通过环境变量读取（见 `main.py` 顶部，均可覆盖默认值）：

```bash
MEMORY_URL=http://127.0.0.1:8420            # TAM memory-core API
MCP_URL=http://127.0.0.1:8432/mcp           # MCP 工具端点
LLM_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1  # OpenAI 兼容 LLM 端点
LLM_API_KEY=sk-noauth                       # LLM key（无鉴权端点填占位）
LLM_MODEL=qwen3.8-27b
MEMORY_ADMIN_KEY=<your-admin-key>           # memory-core admin key（deploy/.admin-key）
MEMORY_TEAM_ID=team-demo0000001             # 默认团队（Web 页可覆盖）
MEMORY_AGENT_ID=agt-demo0000001
```

## 5. 启动

```bash
cd example
python -m uvicorn main:app --host 0.0.0.0 --port 8501

# 健康检查
curl http://localhost:8501/api/health
# {"status":"ok","mcp":"...","memory":"...","llm":"qwen3.8-27b"}
```

浏览器打开 **http://localhost:8501**。

## 6. Web 页面使用

1. **登录**：输入用户名即可（自动生成 `usr-{md5(用户名)[:12]}` / `agt-{md5(用户名)[:12]}`）
2. **高级设置**（可选）：覆盖 Team ID / Agent ID（按人隔离或合并记忆空间用）
3. **对话**：正常聊天；页面展示工具调用步骤
4. **记忆面板**：查看 / 编辑 / 删除当前用户 persona 与记忆，查看场景块

多轮对话在同一 thread（页面自动维持 thread_id）。

## 7. HTTP API

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | /api/chat | 对话（body: message, user_id, thread_id?, team_id?, agent_id?） |
| GET  | /api/memory | 读取 persona + L1 记忆 |
| POST | /api/memory/update | 更新记忆条目 |
| POST | /api/memory/delete | 删除记忆条目 |
| POST | /api/memory/scenario | 场景块查询 |
| GET  | /api/tools | Agent 可用工具列表 |
| GET  | /api/health | 健康检查 |

示例：

```bash
curl -X POST http://localhost:8501/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"你好，我叫小李，喜欢爬山","user_id":"小李"}'

# 返回: {response, thread_id, agent_id, team_id, steps[]}
# 同 thread 追问: 带 "thread_id":"<上一步返回值>"
```

## 8. 记忆生效时序

- **即时**：persona（对话前读取）
- **约 10 分钟后**：L1 提取（L0 空闲 600s 触发）——新对话中的事实进入长期记忆
- **更晚**：persona.md 汇总更新（triggerEveryN=50）

因此刚聊完的内容在同 thread 内靠上下文记得；换新 thread 要等 L1 提取完成后才能"记起"。

## 9. 注意事项

- LLM 端点须从运行 main.py 的机器可达
- 思考型模型（如 qwen3.8）：思考模式开启，单轮回复约 15~20s；L1 提取约 35s（在 180s 超时内）。若需更快可加 `chat_template_kwargs:{enable_thinking:false}`（约快 3 倍）
- main.py 的系统提示经 LangGraph `prompt` callable 瞬态注入（不落 checkpoint），避免 vLLM 严格模板报 "System message must be at the beginning"
- 记忆隔离 scope：`team:{teamId}|agent:{agentId}`，persona 不区分 userId——同名用户共享 agent 记忆空间
