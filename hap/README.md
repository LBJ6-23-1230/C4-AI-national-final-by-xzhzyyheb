# 决赛签名安装包

[下载知学Mate-signed.hap](知学Mate-signed.hap?raw=true) · [版本与 SHA-256](manifest.json) · [安装和验签步骤](../评委部署指导/01-安装HAP与打开工程.md) · [云端评审](../评委部署指导/00-云端评审快速开始.md)

| 项目 | 当前安装包 |
| --- | --- |
| 版本 | `1.0.13`（`1000013`），2026-11-12 构建 |
| 包名 | `com.zhixue.mate` |
| 安装要求 | HarmonyOS API 24 及以上，真机须获当前调试 Profile 授权 |
| 签名 | Debug 调试签名，授权范围与换设备步骤见[签名材料交接](../评委部署指导/05-签名材料交接.md) |
| 默认后端 | `https://47.238.218.213` |

从仓库根目录执行 `Get-FileHash -Algorithm SHA256 -LiteralPath '.\hap\知学Mate-signed.hap'`，与 [manifest.json](manifest.json) 比对。
