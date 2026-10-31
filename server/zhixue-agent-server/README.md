# zhixue-agent-server

「知学 Mate」的 Python Agent 后端。单进程同时提供**两层**能力：

| 层 | 端点 | 职责 |
|---|---|---|
| 自然语言层 | `POST /api/agent/chat` | LLM 意图识别 + 多模态识图 + 6 路子 Agent |
| 结构化工作流层 | `/api/v1/**` | Agent 循环 + **确定性**判分/掌握度/优先级/重规划 |

> **设计纪律（本项目最重要的技术主张）**：大模型只负责「理解意图」与
> 「生成自然语言」，**所有业务计算一律留在确定性代码里**
> （见 `app/decision/`、`app/tools/`）。因此同一份输入永远得到同一个分数，
> 不受模型随机性影响。

## 快速开始

```bash
python -m venv .venv && .venv/Scripts/activate     # Windows
pip install -r requirements.txt
cp .env.example .env                                # 填入 DASHSCOPE_API_KEY（可选）
python run.py                                       # 默认监听 0.0.0.0:5000
```

**不配 Key 也能跑**：聊天层会自动降级为确定性规则，并在回复里明确标注
"本次大模型调用失败/未接入"，**绝不伪装成真实模型输出**
（响应里的 `llmUsed` 字段供前端显示来源标签）。

## LLM 路由

| 变量 | 用途 | 默认值 |
|---|---|---|
| `LLM_MODEL` | 文本意图识别与回复 | `qwen3.8-flash` |
| `LLM_VL_MODEL` | 图片识别 | `qwen3-vl-plus` |
| `LLM_DECISION_MODEL` | 工作流结构化决策 | `qwen3.8-flash` |
| `EMBED_MODEL` | 知识库语义检索向量 | `text-embedding-v3` |
| `LLM_MAX_RETRIES` | 兼容字段；统一运行层固定关闭 SDK 隐式重试 | `0` |
| `LLM_ENABLE_THINKING` | Qwen3 思考模式 | `0` |
| `LLM_REVIEW_WAIT_SECONDS` | 交卷等待逐题解析的预算 | `2` |

两条路径分开是**刻意设计**：识图需要专用视觉模型，工作流决策用更便宜的纯文本
模型，避免占用 VL 配额。不要为了"统一"改成同一个模型。

> 默认模型名来自代码配置。实际可用性应使用目标账号主动验证，配置 Key 本身不能证明模型可用。

> ⚠️ **不要开 SDK 自动重试**：旧实现将 `LLM_TIMEOUT_SECONDS` 作为单次尝试超时，OpenAI SDK
> 默认 `max_retries=2`，一次 30 秒会变成约 90 秒，而前端读超时只有 40 秒 ——
> 表现为"提交失败"，其实服务端还在跑。本次统一运行层已改为总预算并固定禁用 SDK 隐式重试。Qwen3 思考模式默认关闭：出题/解析
> 都是结构化短任务，开启只会慢 2–3 倍（实测 4 题 24.3s → 9.1s）。

文本调用、识图、决策与 Embedding 共用有界调用运行层和连接缓存。仅对 429、500、502、503、504 最多重试一次，短退避计入调用总预算；认证和参数错误直接回落。日志不记录完整题目、响应、密钥或用户身份。

交卷解析默认最多等待 2 秒，先返回确定性解析并完成计分；后台成功后按未变化的提交/错题记录条件补回，重复提交同一请求可读取新解析。默认每个进程 4 个解析任务运行、8 个排队，超限直接降级。后台任务在重启后不恢复。

`LLM_DECISION_TIMEOUT_SECONDS` 默认 8 秒且不超过 `LLM_TIMEOUT_SECONDS`；`LLM_EMBED_TIMEOUT_SECONDS` 默认 30 秒，涵盖整次编码（每批最多 10 条）。`LLM_REVIEW_WORKERS`、`LLM_REVIEW_QUEUE_SIZE`、`LLM_REVIEW_WAIT_SECONDS` 分别控制解析池、队列和交卷等待预算。

出题缓存保留 5 分钟、进程内最多 256 组，按账号、知识点、题量和资料版本区分；已交卷、明确排除、删除或变更的题与资料不复用。跨 worker 不共享此性能缓存。

`GET /api/agent/health` 为被动查询：`configured` 只代表已配置 Key，`verified` 代表 5 分钟内主动验证过当前文本模型，未验证时为 null。旧字段 `llm_ready` 保留为 `configured` 的兼容别名。登录后显式 `POST /api/agent/health` 才发起最小模型验证；每进程最多每分钟一次，不代表识图和 Embedding 模型均可用。

多 worker 部署必须用 SQLite。提交的幂等检查、计分、掌握度及派生记录在同一个 `BEGIN IMMEDIATE` 事务中提交，进程异常时回滚；同一键改交其他答案/目标会返回 409。JSON 后端限制单进程，第二个写进程启动失败。切换后端前停止服务、备份原库，使用项目根目录 `tools/migrate_repository.py --verify` 迁移并逐条比对；工具默认拒绝覆盖已有目标，显式 `--overwrite` 会在事务内替换全部目标记录。然后设置 `ZHIXUE_DB=sqlite`；不要直接切换到一个空 SQLite 库。

Python 3.12 完整锁定安装可用 `pip install -r requirements-lock-py312.txt`。普通 `requirements.txt` 也会读取相同版本约束。运行态保留工具位于项目根 `tools/retention_repository.py`，默认只预览；先备份并停服核对再显式加 `--apply`，不自动清理真实数据。未解决的错题和活动目标引用的数据始终保留。


## 持久化

- **默认**：JSON，落在 `data/repository.json` —— 可直接肉眼查看，便于答辩演示与人工核对
- **多进程部署**：设 `ZHIXUE_DB=sqlite`（或 `ZHIXUE_DB=sqlite:<path>`）
  改用并发安全的 SQLite 后端
- **PostgreSQL**：设 `ZHIXUE_DB=postgresql` + `DATABASE_URL=postgresql+psycopg://...`；
  空库先 `alembic upgrade head`，启动要求 `alembic_version` 等于
  `app/repositories/pg_schema.py` 的 `REVISION`。改完后跑
  `python tools/check_database.py`（项目根）一次查完连接、schema 版本、权限与 `/ready`

> 注意：`data/repository.json` 与 `chat/history.json` 是**运行期状态**，
> 已在 `.gitignore` 中，绝不入库、绝不进交付包。

## 幂等与并发

以下四处「读—改—写」序列均已加锁，避免并发丢更新：

| 位置 | 保护 |
|---|---|
| `chat/history.json` | 进程内锁、跨进程文件锁及原子替换 |
| `POST /api/v1/exercises/{setId}/submit` | 幂等键检查 → 判分 → 掌握度回写整段串行 |
| `EventStore.append`（trace） | 仓储事务，覆盖读取、追加和保存 |
| `_run_saved_workflow`（工作流推进） | 可重入锁及跨进程文件锁；模型调用不占数据库写事务 |

## 鉴权

| 端点 | 说明 |
|---|---|
| `POST /api/v1/auth/register` | 手机号**必填**；重复手机号返回 409 |
| `POST /api/v1/auth/login` | 手机号/昵称与密码登录，或恢复有效 token 会话 |
| `POST /api/v1/auth/send-code` | 手机验证码签发 |
| `POST /api/v1/auth/verify-code` | 验证码校验（200 已存在 / 201 新建） |
| `POST /api/v1/auth/login-with-huawei` | 可信凭证核验尚未接入，当前返回 503、不签发会话 |
| `DELETE /api/v1/auth/account` | 注销账号 |

未配置短信服务商时，开发模式返回 `devCode` 且 `smsDelivered=false`；
生产模式**拒绝**暴露开发码。

> 华为可信登录和生产短信发送适配器尚未实现。开发验证码不代表短信已发送；默认生产模式不会返回开发码。真实模型、短信与华为能力需要独立验收。

## 测试

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1
```

此入口固定工作目录并隔离 `.env`、数据库和模型变量。从项目根目录运行时使用 `server/zhixue-agent-server/tools/run_tests.ps1`。
2026-10-31 修改、实际数据库核验、签名环境及 HTTP 覆盖范围见项目根目录 `修改交付说明-20261031.md`；连接示例为 `examples/backend_connection.py`。

## 契约

`../../contracts/openapi.json` 是前后端唯一接口真源（`api-contract-v0.3`），
`app/contracts/openapi.json` 是逐字节一致的镜像。
请求需携带 `X-API-Contract-Version: api-contract-v0.3`（不带头时放行）。
