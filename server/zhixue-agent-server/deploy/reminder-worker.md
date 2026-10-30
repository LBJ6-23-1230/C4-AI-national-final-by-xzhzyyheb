# 提醒 Worker：本机运行、部署与回退

更新：2026-10-30。API 与 `reminder_worker.py` 是独立进程；不要从每个 Web worker 创建扫描线程。现有 `worker.py` 继续处理讲解等持久化作业，不能替代提醒时钟。

## 本机

在 `server/zhixue-agent-server` 执行，使用与 API 相同的 Python 环境和 `.env`：

```powershell
python reminder_worker.py --once
python reminder_worker.py
```

每 30 秒扫描一次。`--once` 只执行一轮。退出使用 Ctrl+C；生产进程管理器负责重启。Web 与时钟共用现有数据库，不复制用户资料。JSON 仅适合单进程开发；API 与独立 Worker 并行须使用 SQLite 或 PostgreSQL。本工作区既有配置使用 PostgreSQL。

未配置 Push Kit 时仍维护提醒事件与待发记录，不进行外部发送。默认用户主动提醒开关关闭；首页展示不需要通知权限。提醒中心可保存开关、免打扰、摘要时段和紧急例外。

## 云部署增量

`compose.yaml` 已增加 `reminder-worker`，复用 `.env.production`、`.env.worker` 和只读 secrets 挂载。连接预算按 API 两进程、普通 Worker、提醒 Worker 计算，当前默认上限 28 个池连接。

新增集合保存在仓储兼容表 `compatibility_records` 中，沿用现有表结构与事务，不清空课程、学情或计划，无须为了本次新增集合另建数据库。现有 Worker LOGIN 所属角色需由数据库管理员增加权限：

```sql
GRANT INSERT, UPDATE, DELETE ON compatibility_records TO zhixue_worker;
```

新部署的授权模板已同步 `roles.sql`。兼容表承载多个集合，此权限应只授给受信服务进程。生产环境继续使用 PostgreSQL、TLS 和既有结构版本检查。

```sh
docker compose --env-file .env.production up -d api worker reminder-worker
docker compose --env-file .env.production logs --tail=100 reminder-worker
```

## Push Kit 配置边界

用户本次确认暂无已开通项目和手机/平板/手表组合，因此尚未进行平台联调。

可选环境变量：`HUAWEI_PUSH_PROJECT_ID`、`HUAWEI_PUSH_JWT_FILE`、`HUAWEI_PUSH_CATEGORY`。JWT 文件应由外部凭据管理进程定期轮换；当前代码没有代替开发者平台创建服务账号或签发 JWT。容器内建议路径 `/run/secrets/push.jwt`。类别默认 `MARKETING`，正式接入时必须核对项目获准类别与真实业务类型。

适配器发送通知消息，采用最少通知内容、单个最近活跃有效设备、稳定 notifyId、300 秒 TTL 和 15 秒网络超时。点击当前打开应用首页，由同源今日重点进入任务；尚未实现按通知内 eventId 直达某一业务详情的外部深链。

投递记录区分 queued、sending、accepted、failed、cancelled。`accepted` 仅表示平台接受；没有真实回执就不会写 delivered/read。领取租约 60 秒，最多 3 次尝试；显式稍后提醒单独标为 snooze，仍计入每天两次的账号总额度和免打扰规则。成功后清除临时稍后标记。日期变化、完成、删除、忽略等会取消未发任务。发送结果不确定时依赖稳定标识降低重复，不能承诺外部“恰好一次”。

真实 Token 失效码映射、平台送达/点击回执、撤回通知、跨设备离线切换以及手机到手表同步仍需真实项目验证。当前通用 invalid_token 失败分支有解绑处理，但适配器尚未对每个厂商错误码完成映射，不能据此声称已验收全部失效场景。

官方接入依据：

- [通知消息请求](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-send-alert)
- [JWT 鉴权](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-jwt-token)
- [消息请求示例](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-scenariozed-api-request-example)

## 数据和回退

新增集合：`practice_rounds`、`reminder_events`、`reminder_preferences`、`reminder_deliveries`、`reminder_devices`、`reminder_actions`、`agent_handoffs`。已有集合保持原数据；首次读取/业务事件/时钟按真实事实创建记录。

回退先停 `reminder-worker` 并关闭外部提醒，再回退兼容的 API 和 HAP。保留这些新增集合，避免清空作答历史、幂等键和频率记录。若旧版本重新启用旧的本地通知逻辑，应保持通知总开关关闭，直到确认不会与服务端重复发送。不要直接把已经收到新写入的 PostgreSQL 切回旧 JSON 备份。

签名文件、模型 Key、JWT、数据库连接秘密和用户数据不属于交付包。`.env`、`.local-work` 和 `E:/zhixue-signing` 均保留在本机。
