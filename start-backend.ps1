# 知学 Mate 后端启动（PowerShell 5.1+ / 7 均可）
$ErrorActionPreference = 'Stop'

# ---------- 1. 定位工程根（在仓库内任意目录粘贴即可） ----------
$dir = (Get-Location).Path
while ($dir) {
	$probe = Join-Path $dir 'server\zhixue-agent-server\run.py'
	if (Test-Path $probe) { break }
	$parent = Split-Path $dir -Parent
	if (-not $parent -or $parent -eq $dir) { break }
	$dir = $parent
}
if (-not (Test-Path (Join-Path $dir 'server\zhixue-agent-server\run.py'))) {
	$dir = 'E:\C4-AI-national-final-by-xzhzyyheb-main\C4-AI-national-final-by-xzhzyyheb-main'
}
$srv = Join-Path $dir 'server\zhixue-agent-server'
if (-not (Test-Path (Join-Path $srv 'run.py'))) {
	Write-Host "找不到后端目录：$srv" -ForegroundColor Red
	Write-Host '请先把 $dir 改成你的工程根（含 server\zhixue-agent-server 的那一层）'
	return
}
Set-Location $srv
Write-Host "工程根 : $dir"

# ---------- 2. 准备 3.12+ 的虚拟环境 ----------
$venvPy = Join-Path $srv '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPy)) {
	Write-Host '首次运行：创建 .venv（需要本机有 Python 3.12+）' -ForegroundColor Cyan
	if (Get-Command py -ErrorAction SilentlyContinue) { py -3.12 -m venv .venv }
	else { python -m venv .venv }
}
$ver = & $venvPy -c "import sys;print('%d.%d'%sys.version_info[:2])"
if ($ver -notmatch '^3\.(1[2-9])') {
	Write-Host "虚拟环境是 Python $ver，本项目要求 3.12+" -ForegroundColor Red
	Write-Host '装好后删掉 .venv 再跑一次本段；或直接：winget install -e --id Python.Python.3.12'
	return
}
Write-Host "Python : $ver"

# ---------- 3. 依赖（缺 flask 才装，避免每次都联网） ----------
& $venvPy -c "import flask" 2>$null
if ($LASTEXITCODE -ne 0) {
	Write-Host '安装依赖（首次或换机器时需要联网）…' -ForegroundColor Cyan
	& $venvPy -m pip install -r requirements.txt
}

# ---------- 4. .env（已有就不覆盖） ----------
if (-not (Test-Path '.env')) {
	Copy-Item '.env.example' '.env'
	Write-Host '已生成 .env（未填 Key 也能跑，聊天层走确定性规则）' -ForegroundColor Yellow
}

# ---------- 5. 端口检查 ----------
$port = 5000
$busy = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
if ($busy.Count -gt 0) {
	$pid5000 = $busy[0].OwningProcess
	$proc = Get-Process -Id $pid5000 -ErrorAction SilentlyContinue
	Write-Host "5000 端口已被占用：PID=$pid5000 $($proc.ProcessName) $($proc.Path)" -ForegroundColor Yellow
	Write-Host '确认这是旧的后端实例再停：Stop-Process -Id ' -NoNewline
	Write-Host $pid5000 -NoNewline
	Write-Host '    （不要按端口批量杀进程）'
	Write-Host '或改用其它端口：python run.py --port 5300'
	return
}

# ---------- 6. 启动（前台，Ctrl+C 停止） ----------
Write-Host '启动后端…' -ForegroundColor Cyan
& $venvPy run.py
