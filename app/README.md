# 知学 Mate · HarmonyOS 前端

`app/` 是 DevEco Studio 工程。决赛交付版本为 **1.0.13（1000013）**，包名 `com.zhixue.mate`。工程使用 ArkTS / ArkUI 和 HarmonyOS SDK 6.1.1（API 24），注册 35 个页面。先体验应用可使用[签名 HAP](../hap/README.md)。

## 构建与安装

1. 用 DevEco Studio 打开 `app/`，同步 OHPM 依赖并确认已安装 API 24 SDK。Node.js 和 Hvigor 使用 DevEco Studio 的随附版本。
2. 选择 `default` 产品和 `entry` 模块，运行或构建 Debug HAP。源码提供空的签名配置，开发者可使用自己的签名构建，或按[签名材料交接](../评委部署指导/05-签名材料交接.md)配置团队授权。
3. 使用 API 24 模拟器或支持 API 24 及以上的 HarmonyOS 真机。安装决赛调试包时，真机须已获当前 Profile 授权。[HDC 安装与版本核对](../评委部署指导/01-安装HAP与打开工程.md)

## 接口环境

登录页点「查看连接设置」，填入基地址后点「应用此地址」和「检测后端连接」。离线体验使用登录页的「离线演示（无需网络）」。

| 环境 | App 中填写的基地址 |
| --- | --- |
| 香港云端评审 | `https://47.238.218.213`（评审包默认） |
| 与后端在同一电脑的模拟器 | `http://10.0.2.2:5000` |
| 与后端同一可信局域网的真机 | `http://<开发机局域网IP>:5000` |
| USB 开发联调 | 见[真机与模拟器连接步骤](../评委部署指导/01-安装HAP与打开工程.md)和[本地 HTTPS 说明](../评委部署指导/05-签名材料交接.md) |

对话与 `/api/v1/` 工作流共用一个基地址。契约版本为 `api-contract-v0.3`，完整接口见[前端 OpenAPI 镜像](contracts/openapi.json)。

## 工程导航

| 目录 | 用途 |
| --- | --- |
| `AppScope/` | 应用版本、包名及公共资源 |
| `entry/src/main/ets/pages/` | 工作台、对话、知识库、专项练习、学情和个人页 |
| `entry/src/main/ets/api/` | API 客户端、接口环境、登录与离线样例 |
| `entry/src/main/ets/services/` | Agent 桥接、语音、分布式接续、提醒和卡片 |
| `entry/src/main/ets/insightintent/` · `entry/src/main/ets/widget/` | 小艺意图和桌面服务卡片 |
| `tools/` | 前端契约检查和模拟器回归 |

在仓库根目录运行 `python tools/diff_contracts.py` 校验契约，在 `app/` 下运行 `./tools/run_ohos_regression.ps1` 执行设备回归。鸿蒙平台能力按[功能验收与排障](../评委部署指导/04-功能验收与排障.md)检查。
