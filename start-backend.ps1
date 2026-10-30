param(
    [ValidateRange(1, 65535)][int]$Port = 5000,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
$srv = Join-Path $PSScriptRoot 'server\zhixue-agent-server'
if (-not (Test-Path -LiteralPath (Join-Path $srv 'run.py'))) {
    throw "找不到后端目录：$srv"
}
Push-Location -LiteralPath $srv
try {
    $venvPy = Join-Path $srv '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPy)) {
        if ($Check) { throw '缺少 .venv，请先运行 start-backend.ps1 安装环境' }
        if (Get-Command py -ErrorAction SilentlyContinue) { & py -3.12 -m venv .venv }
        else { & python -m venv .venv }
        if ($LASTEXITCODE -ne 0) { throw '创建虚拟环境失败' }
    }
    & $venvPy -c "import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)"
    if ($LASTEXITCODE -ne 0) { throw '需要 Python 3.12 或更新版本' }
    # A missing import prints stderr; Windows PowerShell 5 treats that as a
    # terminating NativeCommandError under Stop, before dependency installation.
    & $venvPy -c "import importlib.util,sys; modules=('flask','flask_cors','openai','dotenv','pypdf','pymupdf','olefile','sqlalchemy','psycopg','alembic','boto3','obs'); sys.exit(0 if all(importlib.util.find_spec(name) is not None for name in modules) else 1)"
    if ($LASTEXITCODE -ne 0) {
        if ($Check) { throw '依赖缺失，请先运行 start-backend.ps1 安装依赖' }
        & $venvPy -m pip install -r requirements.txt
        if ($LASTEXITCODE -ne 0) { throw '安装依赖失败' }
    }
    & $venvPy -m pip check
    if ($LASTEXITCODE -ne 0) { throw '依赖冲突，请检查 requirements.txt' }
    if ($Check) {
        & $venvPy run.py --check --port $Port
        if ($LASTEXITCODE -ne 0) { throw '配置检查失败' }
        return
    }
    if (-not (Test-Path -LiteralPath '.env')) {
        Copy-Item -LiteralPath '.env.example' -Destination '.env'
        Write-Host '已生成 .env；请按需配置模型和短信服务。'
    }
    $busy = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0) { throw "端口 $Port 已占用，请指定 -Port 或确认原进程" }
    & $venvPy run.py --port $Port
    if ($LASTEXITCODE -ne 0) { throw '后端退出异常，请查看上方日志' }
} finally {
    Pop-Location
}
