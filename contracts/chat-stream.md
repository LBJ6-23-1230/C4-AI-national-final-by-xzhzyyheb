# 聊天进度扩展

`POST /api/agent/chat` 的原 JSON 请求体、认证和最终响应字段不变。调用方通过 `Accept: text/event-stream` 主动启用进度；未启用的客户端仍收到原 `application/json`。这是可选传输扩展，保留 v0.3 的现有 JSON 契约。

事件使用 UTF-8 SSE、LF 分隔。`data` 是一个 JSON 值，服务端将中文转义以容忍任意网络分包。每 5 秒可以收到注释心跳。服务端设置 `X-Accel-Buffering: no`，部署代理不能强制覆盖为缓冲。

- `progress`：`{stage, message, reply}`。阶段为 accepted、context、intent、analysis、saving、coordination；按实际经过的步骤发送，不保证所有步骤都有。reply 通常为空；只有已校验的只读回复在等待学习计划同步时可以提前展示。进度不得触发画像更新、卡片导航、评分或本地历史保存。
- `result`：与旧 JSON 成功响应完全相同的对象。收到后才执行原客户端更新逻辑。
- `error`：`{status, body}`，body 使用服务端错误对象。连接建立后的失败通过此终态表示，不伪装为成功。

认证拒绝、接入容量不足等可在建立流之前返回普通 JSON 错误。新客户端同样接受旧服务端的 JSON 响应，不自动重发 POST。缺少终态即连接中断；用户可查看历史后决定是否重试。断线不撤销已经接收的服务端操作，服务端仍按原逻辑完成一次写入。

这里只发送真实阶段与已校验回复，不展示模型内部思维链，也不将未完成的 JSON/原始 token 当成最终结果。读取上限覆盖分类、回答和计划同步的累计时间；连接超时仍保持原配置。超时上限放宽不是性能收益，性能收益来自工作流省略无选择的模型决策与向量批处理缓存/并发。

验证：`tools/check_chat_stream.js` 执行真实 ArkTS 解析器和网络桥，覆盖分包、中文、旧响应、错误、终态缺失和请求释放；`tests/test_response_pipeline.py` 覆盖身份、首次反馈、单次持久化和容量限制。
