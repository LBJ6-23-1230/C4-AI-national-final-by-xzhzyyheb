# 签名配置由本机 DevEco 管理，不在脚本内存储密码或私钥路径。
param([string]$DevEcoHome = 'D:/develop/DevEco Studio')
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build_phase9.ps1') -DevEcoHome $DevEcoHome
