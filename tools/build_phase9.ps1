param(
    [string]$DevEcoHome = 'D:/DevEco/DevEco Studio',
    [string]$SdkHome = '',
    [ValidateSet('debug', 'release')][string]$BuildMode = 'debug'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($BuildMode -eq 'release') {
    $taskEnvironment = Get-Content -Raw -LiteralPath (Join-Path $root 'app/entry/src/main/ets/api/BuildEnvironment.ets')
    if ($taskEnvironment -notmatch "NAME: string = 'production'" -or $taskEnvironment -notmatch 'ALLOW_DEBUG: boolean = false' -or $taskEnvironment -notmatch "API_URL: string = 'https://") {
        throw 'Prepare a production HTTPS environment with tools/prepare_app_environment.py before release packaging.'
    }
}
$modules = Join-Path $root '.local-work/node_modules'
$scope = Join-Path $modules '@ohos'
New-Item -ItemType Directory -Force -Path $scope | Out-Null
foreach ($name in @('hvigor', 'hvigor-ohos-plugin')) {
    $link = Join-Path $scope $name
    if (-not (Test-Path -LiteralPath $link)) {
        New-Item -ItemType Junction -Path $link -Target (Join-Path $DevEcoHome "tools/hvigor/$name") | Out-Null
    }
}
$env:NODE_HOME = Join-Path $DevEcoHome 'tools/node'
$env:JAVA_HOME = Join-Path $DevEcoHome 'jbr'
$env:DEVECO_SDK_HOME = if ($SdkHome) { $SdkHome } else { Join-Path $DevEcoHome 'sdk' }
$env:PATH = (Join-Path $env:DEVECO_SDK_HOME 'default/openharmony/previewer/common/bin') + ';' + $env:PATH
$env:HVIGOR_USER_HOME = Join-Path $root '.local-work/hvigor-phase9'
$env:NODE_PATH = $modules
Push-Location (Join-Path $root 'app')
try {
    & (Join-Path $env:NODE_HOME 'node.exe') (Join-Path $DevEcoHome 'tools/hvigor/hvigor/bin/hvigor.js') --mode module -p product=default -p module=entry@default -p "buildMode=$BuildMode" clean assembleHap --no-daemon
    if ($LASTEXITCODE -ne 0) { throw "HAP build failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}
