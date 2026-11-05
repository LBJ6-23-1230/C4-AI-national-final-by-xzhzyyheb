# 最新安装包

`知学Mate-signed.hap` 已更新为 **2026-11-05 Push 版 debug 签名包**，代码基线为 2026-11-04 的 `5016807`（待办统计统一修复 + “我的”统计刷新修复）。

- 大小：**5,292,684 字节**
- SHA-256：`ed8ed4f053a2d19b80402e3a1ef70e5dc1674f14dfe56fd36b9472ab4341678e`
- 构建：2026-11-05 11:05，debug 构建
- 签名：使用 2026-11-05 新建的调试 Profile `zhixue-debug-push-20261105`
- 旧 Profile 备份：`zhixue-signing/com.zhixue.mateDebug-20261105-before-push.p7b.bak`
- 验签：官方 `verify-app` 通过（`profile type is: debug`、`Digest verify result: true`）
- 安装：Pura 90 模拟器覆盖安装、启动通过
- 检查：15 项统计专项 + 11 项待办/同步检查通过
- 说明：`app-privilege-capabilities` 为空是正常的（应用特权字段，不是 Push 开关）；Push 能力由 AGC 推送服务/开放能力控制
- 注意：默认接口仍是 `http://10.0.2.2:5000`；真机演示前需在 App「接口环境」改为电脑 WLAN IP

[项目核查报告](../项目核查报告-20261105.md)
