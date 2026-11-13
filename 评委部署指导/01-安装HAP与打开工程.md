# 01 安装 HAP 与打开 DevEco Studio 工程

HAP 是 HarmonyOS 的应用安装包。只想体验作品，可以直接安装 `hap/知学Mate-signed.hap`。需要检查源码或重新构建时，再打开 `app/` 工程。请先完整解压 ZIP，例如解压到 `C:\C4` 后进入 `C:\C4\ZhixueMate`。DevEco 工程的整个绝对路径应使用英文字母、数字或普通路径符号，避免中文和过长路径。以下 PowerShell 命令均从解压后的项目根目录执行。

## 1. 准备设备和工具

1. 在 Windows 电脑安装 DevEco Studio 并完成首次设置。本项目使用 **HarmonyOS SDK 6.1.1（API 24）**、DevEco 自带的 Node.js 和 Hvigor。SDK Manager 中应看到 API 24 已安装。[华为 DevEco Studio 下载](https://developer.huawei.com/consumer/cn/deveco-studio/)
2. 有鸿蒙手机或平板时，请用支持 **API 24 或更高**的系统。设置中的 HarmonyOS 版本号可以作为初筛，下面的 HDC 命令可查 API 级别。HarmonyOS 4.x 设备无法安装这个 HAP。
3. 没有适用真机时，在 DevEco Studio 的 Device Manager 中下载并启动一个 **API 24** 的本地手机或平板模拟器。首次创建时可能需要华为账号登录并下载较大的镜像。等待模拟器进入桌面后再安装。
4. 真机安装需要签名 Profile 已授权该设备。请提前把本次评审所用设备交给团队确认；临时换设备也要确认。模拟器与真机分别验证，以实际安装结果为准。

## 2. 验证并安装交付 HAP

打开 PowerShell，进入解压后包含 `app`、`hap`、`server` 的目录。将命令第一行的 DevEco Studio 路径改为自己的安装位置。若安装在其他位置，可在 DevEco Studio 的 SDK 路径设置里找到 SDK，再定位其中的 `openharmony\toolchains\hdc.exe`。

```powershell
$DevEcoDir = 'C:\Program Files\Huawei\DevEco Studio'
$Hdc = Join-Path $DevEcoDir 'sdk\default\openharmony\toolchains\hdc.exe'
Test-Path -LiteralPath $Hdc
Get-Content -LiteralPath '.\hap\manifest.json' -Encoding UTF8
Get-FileHash -Algorithm SHA256 -LiteralPath '.\hap\知学Mate-signed.hap'
& $Hdc list targets
```

`Test-Path` 应显示 `True`。核对 HAP 的 SHA-256 与 `manifest.json` 一致，大小写差异可忽略。交付版本和签名说明见 [HAP 说明](../hap/README.md)。若只收到单个 HAP，请让团队提供对应清单，避免拿错历史包。

连接真机时，请使用能传数据的 USB 线并解锁设备。开启开发者选项和 USB 调试，接受设备上弹出的调试授权，再运行 `list targets`。使用模拟器时，启动后它也应出现在列表里。以下命令适用于只连接一台目标设备时。

```powershell
& $Hdc shell param get const.ohos.apiversion
& $Hdc install -r '.\hap\知学Mate-signed.hap'
& $Hdc shell aa start -a EntryAbility -b com.zhixue.mate
& $Hdc shell bm dump -n com.zhixue.mate
```

第一行应返回 `24` 或更高。看到 `install bundle successfully` 后，应用应出现在设备桌面。`aa start` 用于打开应用，`bm dump` 可查安装后的 `versionName` 和 `versionCode`。有多台设备时，在子命令前加入 `-t '<list targets 中本次目标的连接标识>'`，或者暂时断开其他设备。连接标识用于本机命令，真机 UDID 只通过团队指定的私密渠道提供给签名管理员。

若 `-r` 安装提示签名不兼容，先问团队确认旧包来源和是否需要保留设备上的应用数据。覆盖需要兼容的签名；卸载会删除该设备上的本地应用数据。若提示 Profile 或设备授权错误，请保留错误码，让签名管理员确认设备是否在当前授权范围，再领取重签名包。

## 3. 选择离线、在线或真机联调

第一次打开应用，在登录页底部「免登录体验」选择「离线演示（无需网络）」即可查看内置样例。体验真实后端时，先按本目录的后端手册启动服务，然后在登录页华为账号入口下点「查看连接设置」。进入应用后，也可在「我的 → 账号、安全与隐私」连续点版本号五次打开「接口环境」。

| 实际运行环境 | 在 App 中填写的根地址 |
| --- | --- |
| 后端和模拟器运行在同一台电脑 | `http://10.0.2.2:5000` |
| 真机与后端电脑连接同一个可信局域网 | `http://<后端电脑 WLAN 的 IPv4>:5000` |
| USB 真机使用开发包，电脑已启用 HDC 反向转发 | `http://127.0.0.1:5000` |
| 已部署 HTTPS 的后端 | `https://<实际 API 域名>` |

填好地址后，点「应用此地址」，再点「检测后端连接」。状态应显示「真实后端」。回到登录页，点「跳过登录，在线体验」即可检查联机路径。用本机 PowerShell 或浏览器访问 `http://127.0.0.1:5000/ready` 可检查电脑上的 API。真机使用局域网时，可在后端电脑运行 `ipconfig` 查 WLAN 的 IPv4，并用真机浏览器先测试 `http://<该地址>:5000/ready`。校园 Wi-Fi 若隔离设备，换可信热点、使用 USB 或改用可达的 HTTPS 后端。

USB 真机的 SQLite 评审路线先按后端手册前台启动 API。保留后端窗口，另开 PowerShell 窗口，设置本节上面的 `$Hdc`，确认真机出现在列表，然后执行以下命令。

```powershell
& $Hdc list targets
& $Hdc rport tcp:5000 tcp:5000
& $Hdc fport ls
```

有多台目标时，在子命令前加 `-t '<连接标识>'`。USB 拔插后重新执行转发。回到 App 的「接口环境」点「使用 USB 联调地址」，开发模式下使用 `http://127.0.0.1:5000`。具备 Windows CIM 进程查询权限且已安装后端依赖时，可使用 `start-all.ps1 -NoWorker -HdcPath $Hdc` 在后台管理 API 和转发。

若团队安排 USB HTTPS 专项联调，原机另需启动配套 TLS 代理，并反向转发 55001，再手动填写 `https://127.0.0.1:55001`，见 [05 签名材料交接](05-签名材料交接.md)。华为账号登录还需要设备系统账号、后端 OAuth 配置及匹配的应用签名。用访客路径可以先独立验证 HAP、网络和基础业务。

## 4. 在 DevEco Studio 中同步和构建

1. 通过 **File → Open** 选择解压目录下的 **`app` 文件夹**。该层应直接包含 `build-profile.json5`、`oh-package.json5`、`AppScope` 和 `entry`。
2. 确认打开的是团队提供的源码，然后按 IDE 提示信任工程并等待同步完成。安装提示缺失的 API 24 SDK。若首次下载 `@ohos/hypium` 或 `@ohos/hamock` 失败，检查开发机网络、代理及 OHPM 可用性后重新同步。
3. 选择产品 `default` 和模块 `entry`，构建 Debug HAP。构建成功时在 Build 输出中可见 `BUILD SUCCESSFUL`，文件位于 `app/entry/build/default/outputs/default/`。交付源码已去除团队开发机的本地签名配置。没有配置个人签名时，可能得到 `entry-default-unsigned.hap`，这可验证源码编译。要安装运行，请使用交付签名 HAP 或按下一节签名。
4. 已配置有效签名且目标已授权时，可在 IDE 的目标列表中选定模拟器或真机，再点 Run。完成后到「我的 → 账号、安全与隐私」核对版本。

如果需要在 Windows 命令行复核构建，可在解压根目录使用随包脚本。若系统阻止执行脚本，可先运行 `powershell -NoProfile -ExecutionPolicy Bypass` 打开本次操作用的 PowerShell 窗口。按本机安装位置修改第一行。脚本在工程内部准备 SDK 副本并执行干净构建。

```powershell
$DevEcoDir = 'C:\Program Files\Huawei\DevEco Studio'
$SdkDir = & .\tools\prepare_sdk_workspace.ps1 -DevEcoHome $DevEcoDir
& .\tools\build_phase9.ps1 -DevEcoHome $DevEcoDir -SdkHome $SdkDir
```

若出现 `00306003 Invalid project path`，把整个 `ZhixueMate` 移到如 `C:\C4\ZhixueMate` 的英文短路径，再重新打开 `app/`。

## 5. 换设备、重签名与能力交接

通常由团队管理员重新签名后发给评委，评委只接收 HAP、校验清单和说明。若评委确需用自己管理的应用重签源码，在 DevEco Studio 的 **File → Project Structure → Signing Configs** 配置同一套调试证书 `.cer`、签名密钥库 `.p12` 和由管理员为对应应用、证书、目标设备签发的 `.p7b`。密钥别名和密码只在本机填写，保留 Profile 与证书的配套关系。API 根地址可在 App 内切换，通常无需为了换后端而重签。

调试 Profile 有设备范围和有效期。团队管理员应在 AGC 添加设备后重发 Profile，重新构建和验签，再在该设备验证安装和启动。个人签名可用于检查源码运行。验证原项目的华为账号、Push 或小艺绑定能力时，仍需由团队核对应用包名、证书和开放平台配置。

完成后可按[功能验收与排障](04-功能验收与排障.md)逐项检查。
