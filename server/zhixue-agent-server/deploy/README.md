# 云端部署与迁移手册（2026-10-27）

这是按两份部署方案实现的第一版云端工程。开发环境仍支持 JSON/SQLite；云端使用 PostgreSQL、独立 Worker、私有 OBS/S3 和 HTTPS 网关。**云账号、域名、证书、RDS、OBS 权限与发布签名需要提供真实配置；本次没有购买或上线云资源。**

## 1. 环境和连接预算

开发、测试、决赛演示、生产分别使用独立数据库/凭据/桶。演示可保留 `DEMO_ENABLED=true`，生产必须为 false；生产禁止 JSON/SQLite、开发验证码、重置工具和通配 CORS，并强制 PostgreSQL `verify-full` 及 CA 证书。

本次真实测试版本：PostgreSQL 17.11 / Python 3.12。云上使用厂商支持的 PostgreSQL 17 补丁版本，并在测试环境先验证。数据库、ECS、OBS 同地域；ECS/RDS 同 VPC。公网开放 443，80 用于 HTTPS 跳转；5432 和 API 8000 不对公网开放。

默认连接预算：API 2 个进程 × (5 池连接 + 2 溢出) + 作业 Worker (5 + 2) + 提醒 Worker (5 + 2) = 最多 28，另给迁移、监控、备份预留。增加实例/进程前重新计算。Gunicorn 不 preload，连接池有存活检查，跨 fork 会重新建池。

2026-10-30 新增独立 `reminder-worker`，配置、权限增量与回退见 [提醒 Worker 说明](reminder-worker.md)。未配置 Push Kit 时仅维护事件和队列，不发送外部通知。

## 2. 构建镜像和配置

在本目录执行（Linux，已安装 Docker Compose v2）：

```sh
cp .env.production.example .env.production
cp .env.worker.example .env.worker
cp .env.migration.example .env.migration
mkdir -p deploy/certs deploy/runtime-secrets
# 填入真实配置；生产、Worker、迁移角色分别管理。
# deploy/certs/fullchain.pem + privkey.pem 是域名证书。
# deploy/runtime-secrets/rds-ca.pem 是云数据库受信 CA。
docker build -t registry.your-domain/zhixue:20261027-01 .
docker push registry.your-domain/zhixue:20261027-01
```

镜像标签应固定并记录摘要，正式发布最好用 `registry/...@sha256:...`。不要使用 `latest`。`.env*` 的真实配置、证书、私钥、聊天记录和业务库不会进入镜像；示例文件不含密钥。`.env.production` 中的 `APP_IMAGE` 设为构建出的镜像。

OBS 使用 `FILE_STORAGE=obs` 和华为官方 Python SDK；支持 S3 兼容服务时使用 `FILE_STORAGE=s3`。桶必须私有，账号仅授予指定桶/前缀的读写删除权限。下载先检查文档归属，再生成 120 秒授权地址；不要把签名地址记入日志。SDK 使用 CA 校验，原文件有随机对象键、实际大小和 SHA-256 校验。

## 3. 首次建库

先由运维创建独立数据库与迁移 LOGIN 角色；应用角色不能建表。CA 文件需要容器 UID 10001 可读。

```sh
docker compose --env-file .env.production --profile tools run --rm migrate
```

结构版本为 `20261030_03`。API/Worker 启动只检查连接和版本，不执行 DDL。迁移成功后由数据库管理员执行 `deploy/roles.sql`，再把 `zhixue_api` 和 `zhixue_worker` 分别授予对应的 LOGIN 角色。API/Worker 的环境文件不得使用迁移角色。后续迁移新增表时，需要复核授权；默认不向应用授予 CREATE。

已有结构版本不符或数据库不可用时启动失败，禁止自动创建 JSON 空库。不要通过删掉 `alembic_version` 或强制 stamp 绕过检查。

## 4. JSON/SQLite 与聊天历史切换

先停止全部写入和旧后台任务，备份原库、`history.json` 以及原文件。迁移命令在后端根目录执行；环境中设置目标 `DATABASE_URL`，并用迁移/导入角色操作。

```sh
# 仅核查源数据和目标冲突，不写入（默认行为）。
python tools/migrate_postgresql.py --source /backup/repository.json --history /backup/history.json --report /backup/dry-run.json
# 确认报告后导入。SQLite 源也支持 --source /backup/repository.sqlite。
python tools/migrate_postgresql.py --source /backup/repository.json --history /backup/history.json --apply --report /backup/import.json
python tools/migrate_postgresql.py --source /backup/repository.json --history /backup/history.json --verify-only --report /backup/verify.json
```

检测规范化手机号重复、孤立归属、文档/知识库/切片跨账号引用及目标记录冲突；导入在一个事务内完成，逐条核验失败会回滚。重复运行相同源是幂等的，目标不同内容不会被覆盖。报告只有计数、ID、错误位置和摘要，不应作为公开材料分发。

历史无用户分桶的聊天数组归给 demo-user；每个用户最多导入最近 50 轮，与既有保留规则一致。历史文档如果旧系统没有保存原文件，迁移只能保留解析记录和切片，不能还原原 PDF；新上传的文档才具有原文件 SHA-256。迁移不会编造丢失来源。

**目标 PostgreSQL 收到新写入后，不可直接改回旧 JSON。** 回退优先使用兼容当前结构的旧应用镜像，数据仍保留在 PostgreSQL。数据回退需要维护窗口和新增数据核验。

## 5. 发布、探针和运行

```sh
export APP_IMAGE=registry.your-domain/zhixue:20261027-01
sh deploy/release.sh
curl --fail https://your-api-domain/health
curl --fail https://your-api-domain/ready
docker compose --env-file .env.production ps
docker compose --env-file .env.production logs --tail=100 worker
```

`/health` 仅表示进程存活；`/ready` 检查数据库及结构版本，断库返回 503。模型暂时不可用不会让就绪探针重启 API。数据库请求失败返回明确的 503，界面不能显示“保存成功”。

API/Worker 都会自动重启，日志轮转 10MB × 5。API 的请求日志不包含查询串、认证头或请求体，响应包含服务端生成的 request ID。Worker 的失败日志只记录任务 ID/类型，不输出用户内容或供应商错误原文。

Worker SIGTERM 后停止领新任务，当前任务有时间完成；强杀后租约过期会重领。任务最多 4 次尝试，有退避、心跳和租约令牌；结果在短事务内进行条件写回并确认。即使最后一次执行崩溃，也会在恢复时结束失败状态，不会永久 pending。

一次交卷保存答案快照、确定性评分、掌握度、错题、计划、轨迹及讲解任务。同键同内容重放原结果，同键不同内容返回 409。外部模型调用和对象上传均在数据库事务外。

画像偏好保存必须传 `expectedProfileVersion`，过期返回 409；计划预算已有 `expectedPlanVersion`。为兼容旧的多表业务操作，未显式指定用户的事务仍使用全局 advisory lock；交卷支持用户锁和全局共享保护。当前适合小规模试运行，不能据此宣称已完成高并发容量验收。

## 6. 备份、恢复与监控

云平台设置自动备份/PITR/保留期和告警；主备不能替代备份。逻辑备份可用 `deploy/backup.sh`，凭据放入受保护的 libpq service/password 文件，用 `PGSERVICE` 指定；脚本不在命令行放密码。

```sh
export PGSERVICE=zhixue-backup
export BACKUP_DIR=/secure-separate-volume/zhixue
sh deploy/backup.sh
# 恢复仅指向新建的数据库，核验通过后再切流量。
pg_restore --exit-on-error --no-owner --dbname=NEW_RECOVERY_DATABASE /backup/zhixue.dump
```

本次可复现的本机演练命令：

```sh
# 必须是名称以 zhixue_test 开头的隔离测试库。
export ZHIXUE_TEST_DATABASE_URL='postgresql+psycopg://.../zhixue_test_rehearsal'
python tools/rehearse_postgresql.py --pg-bin /usr/lib/postgresql/17/bin --output /protected/rehearsal
```

该工具只生成测试数据，创建新 schema 和新恢复库，不删除现有库。报告逐条核验账号、画像、提交、文档关系、切片、聊天消息及会话。它验证逻辑备份恢复，**不等于已验证云端 PITR、RPO/RTO 或 OBS 恢复**。

监控至少包括：API 5xx/延迟、数据库容量/连接/锁等待、任务 queued/running/failed 数量、最老等待时间、模型失败、文件删除失败、备份失败。可在受控只读连接下检查：

```sql
SELECT status, count(*), min(created_at) FROM jobs GROUP BY status;
SELECT count(*) FROM jobs WHERE status='running' AND locked_until < now();
SELECT count(*) FROM file_objects WHERE status='uploaded';
```

上传对象与数据库不是分布式事务：上传后的数据库失败会尝试删除对象；进程恰好崩溃仍可能留下孤立对象。正式上线前建立带宽限期的 OBS 清单与 file_objects 对账，不要按对象年龄直接删除所有原文件。失败删除任务需要告警及人工重试。

## 7. 已实现边界

核心领域分表并有常用类型字段/索引，复杂画像、题目、计划和响应保留 JSONB，以兼容现有 API；不是方案中全部细粒度关系表的最终形态。文档与知识库、切片与文档有归属复合外键，手机号、提交幂等键及消息顺序有唯一约束。其余少量集合使用兼容表。尚未实现全库 RLS、所有列表分页或完整审计平台。

云端注销已按用户明确授权实现：停用、撤销会话、清除该用户私有业务数据、取消旧任务、异步删除原文件；保留匿名停用标记。JSON/SQLite 备用环境保留原先的停用行为。历史备份中的副本按备份保留策略过期，不宣称即时清除全部备份。

短信提供商和可信华为登录仍需外部服务接入；当前未接入时返回真实错误，不回显生产验证码。正式上线前需要验证账号注册策略、隐私政策、服务额度、真机移动网络和发布签名。不要将本次本机测试报告当作正式云端验收。

参考：[SQLAlchemy 连接池](https://docs.sqlalchemy.org/en/20/core/pooling.html)、[PostgreSQL 锁](https://www.postgresql.org/docs/current/explicit-locking.html)、[华为 OBS SDK](https://github.com/huaweicloud/huaweicloud-sdk-python-obs)。


## 2026-10-30 课程与作业同步升级

新增 `learning_courses`、`learning_assignments`，迁移头为 `20261030_03`。更新 API 前先备份，并通过迁移角色执行 `alembic upgrade head`；应用启动不执行 DDL。旧客户端空作业列表不再代表删除。两台设备安装新版，原设备首次登录以补充方式迁移课程与 DDL，再由另一设备恢复。
