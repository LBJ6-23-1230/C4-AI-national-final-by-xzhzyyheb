# 同手机号多账号更新

同一手机号可以注册多个独立账号；各账号仍使用独立 userId 隔离数据。多账号登录弹出选择面板，显示昵称、头像、年级、创建时间。没有头像时显示昵称首字，未填年级显示“未设置”。

密码登录选择后校验所选账号的密码；若账号密码不同，可在选择面板输入对应密码重试。验证码登录只消费一次验证码，再用五分钟有效、一次性的选择凭据选择账号。选择完成前不签发登录会话。

新增 POST /api/v1/auth/select-account，接收 selectionToken、accountId 和可选 password。登录接口多账号响应为 accounts 和 selectionToken。

## 生效步骤

1. PostgreSQL 环境在后端目录执行 `python -m alembic upgrade head`，升级到 20261028_02，解除手机号唯一约束，保留查询索引。使用既有数据库迁移连接配置，保留全部账号和学习数据。
2. 重启后端，使新注册规则和选择接口生效。
3. 使用 DevEco 本机签名配置构建并安装新版应用。目前构建的是 app/entry/build/default/outputs/default/entry-default-unsigned.hap，尚未签名、安装。

只更新客户端不足以让旧后端支持同手机号多账号。

## 验证范围

登录后端回归测试、前端账号选择及会话隔离检查、接口契约同步检查通过。ArkTS 编译和 HAP 构建通过。PostgreSQL 迁移链和模式检查通过；未在实际 PostgreSQL 上执行迁移，未完成设备界面验证。
