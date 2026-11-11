param([string]$Python = 'python', [string[]]$TestArgs = @('tests', '-q', '-p', 'no:cacheprovider'))
$ErrorActionPreference = 'Stop'
$taskServer = Split-Path $PSScriptRoot -Parent
$taskKeys = @('PYTHON_DOTENV_DISABLED','ZHIXUE_DB','DEMO_ENABLED','ZHIXUE_ENV','ZHIXUE_ENABLE_DEV_TOOLS','DASHSCOPE_API_KEY','DATABASE_URL')
$taskSaved = @{}
foreach ($taskKey in $taskKeys) { $taskSaved[$taskKey] = [Environment]::GetEnvironmentVariable($taskKey, 'Process') }
Push-Location -LiteralPath $taskServer
try {
    $env:PYTHON_DOTENV_DISABLED='1'
    $env:ZHIXUE_DB='json'
    $env:DEMO_ENABLED='true'
    $env:ZHIXUE_ENV='development'
    $env:ZHIXUE_ENABLE_DEV_TOOLS='1'
    $env:DASHSCOPE_API_KEY=''
    $env:DATABASE_URL=''
    & $Python -m pytest @TestArgs
    $taskExitCode = $LASTEXITCODE
} finally {
    Pop-Location
    foreach ($taskKey in $taskKeys) { [Environment]::SetEnvironmentVariable($taskKey, $taskSaved[$taskKey], 'Process') }
}
exit $taskExitCode
