param([string]$DevEcoHome = 'D:/develop/DevEco Studio')
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build_phase9.ps1') -DevEcoHome $DevEcoHome
