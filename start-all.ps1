param(
  [int]$Port = 5000,
  [switch]$Stop,
  [switch]$Status,
  [switch]$Restart,
  [switch]$NoWorker
)

# 一键启动 / 停止 / 查看 知学 Mate 后端：
#   API    : run.py --port 5000
#   Worker : worker.py（知识库解析、交卷解析等后台任务）
#
# 用法：
#   .\start-all.ps1            # 缺什么补什么；已在运行就跳过
#   .\start-all.ps1 -Status    # 只看状态
#   .\start-all.ps1 -Restart   # 先停再起
#   .\start-all.ps1 -Stop      # 停 API + Worker
#   .\start-all.ps1 -NoWorker  # 只起 API（调试用）

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Srv = Join-Path $Root 'server\zhixue-agent-server'
$Venv = Join-Path $Srv '.venv\Scripts\python.exe'
$LogDir = Join-Path $Root 'logs'
$ApiOut = Join-Path $LogDir "api-$Port.log"
$ApiErr = Join-Path $LogDir "api-$Port.err.log"
$WorkerOut = Join-Path $LogDir 'worker.log'
$WorkerErr = Join-Path $LogDir 'worker.err.log'

if (-not (Test-Path -LiteralPath $Venv)) {
  throw "找不到虚拟环境：$Venv`n请先在 server\zhixue-agent-server 下创建 .venv 并安装依赖。"
}

function Get-ApiPid {
  $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($listener) { return [int]$listener.OwningProcess }
  return 0
}

function Get-ParentPid {
  param([int]$ProcessId)
  $row = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if ($row) { return [int]$row.ParentProcessId }
  return 0
}

function Test-Ready {
  try {
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/ready" -TimeoutSec 3
    return ($response.status -eq 'ready')
  } catch {
    return $false
  }
}

function Get-WorkerProcesses {
  $all = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue)
  $matched = @()
  foreach ($process in $all) {
    if ($process.CommandLine -and $process.CommandLine -match 'worker\.py') {
      $parent = $all | Where-Object { $_.ProcessId -eq $process.ParentProcessId } | Select-Object -First 1
      if (($process.CommandLine -match [regex]::Escape($Srv)) -or
          ($parent -and $parent.CommandLine -and $parent.CommandLine -match [regex]::Escape($Srv))) {
        $matched += $process
      }
    }
  }
  return $matched
}

function Stop-ProcessTree {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return }
  try {
    & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
  } catch {
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
  }
}

function Show-Status {
  $apiPid = Get-ApiPid
  $ready = $false
  if ($apiPid -gt 0) { $ready = Test-Ready }
  $workers = @(Get-WorkerProcesses)

  Write-Host ''
  Write-Host '=== 知学 Mate 后端状态 ===' -ForegroundColor Cyan
  if ($apiPid -gt 0) {
    $state = if ($ready) { '/ready 200' } else { '端口占用但 /ready 不通' }
    Write-Host ("  API    : 运行中  PID {0}  {1}" -f $apiPid, $state) -ForegroundColor Green
  } else {
    Write-Host '  API    : 未运行' -ForegroundColor Yellow
  }
  if ($workers.Count -gt 0) {
    $pids = ($workers | ForEach-Object { $_.ProcessId }) -join ', '
    Write-Host ("  Worker : 运行中  PID {0}" -f $pids) -ForegroundColor Green
  } else {
    Write-Host '  Worker : 未运行（知识库解析不会推进）' -ForegroundColor Yellow
  }
  Write-Host ("  日志   : {0}" -f $LogDir)
  Write-Host ''
  if ($apiPid -gt 0 -and $ready -and ($workers.Count -gt 0 -or $NoWorker)) { return $true }
  if ($apiPid -eq 0 -and $workers.Count -eq 0 -and -not $NoWorker) { return $false }
  return $false
}

function Stop-All {
  $apiPid = Get-ApiPid
  $workers = @(Get-WorkerProcesses)
  Write-Host ''
  Write-Host '=== 停止后端 ===' -ForegroundColor Cyan
  if ($apiPid -gt 0) {
    $parent = Get-ParentPid -ProcessId $apiPid
    Stop-ProcessTree -ProcessId $apiPid
    if ($parent -gt 0) { Stop-ProcessTree -ProcessId $parent }
    Write-Host ("  API 已停止（PID {0}）" -f $apiPid) -ForegroundColor Green
  } else {
    Write-Host '  API 本来就没运行' -ForegroundColor Yellow
  }
  foreach ($worker in $workers) {
    Stop-ProcessTree -ProcessId $worker.ProcessId
    Write-Host ("  Worker 已停止（PID {0}）" -f $worker.ProcessId) -ForegroundColor Green
  }
  if ($workers.Count -eq 0) { Write-Host '  Worker 本来就没运行' -ForegroundColor Yellow }
  Start-Sleep -Seconds 2
  Write-Host ''
}

function Start-All {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  $env:PYTHONIOENCODING = 'utf-8'

  $apiPid = Get-ApiPid
  if ($apiPid -gt 0) {
    if (-not (Test-Ready)) {
      throw "端口 $Port 已被 PID $apiPid 占用，但 /ready 不通。请先 .\start-all.ps1 -Stop，或检查日志：$ApiErr"
    }
    Write-Host ("API 已在运行（PID {0}），跳过启动。" -f $apiPid) -ForegroundColor Green
  } else {
    Write-Host '启动 API…'
    $api = Start-Process -FilePath $Venv -ArgumentList @('run.py', '--port', "$Port") `
      -WorkingDirectory $Srv -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $ApiOut -RedirectStandardError $ApiErr
    $ready = $false
    for ($i = 1; $i -le 60; $i++) {
      Start-Sleep -Seconds 1
      if (Test-Ready) { $ready = $true; break }
      if ($api.HasExited) { break }
    }
    if (-not $ready) {
      $tail = ''
      if (Test-Path -LiteralPath $ApiErr) { $tail = (Get-Content -LiteralPath $ApiErr -Tail 20 -Encoding UTF8) -join "`n" }
      throw "API 未在 60 秒内就绪。请查看日志：$ApiErr`n$tail"
    }
    Write-Host ("API 已就绪（PID {0}，http://127.0.0.1:{1}）" -f $api.Id, $Port) -ForegroundColor Green
  }

  if ($NoWorker) {
    Write-Host '按 -NoWorker 跳过 Worker。' -ForegroundColor Yellow
    return
  }

  $workers = @(Get-WorkerProcesses)
  if ($workers.Count -gt 0) {
    $pids = ($workers | ForEach-Object { $_.ProcessId }) -join ', '
    Write-Host ("Worker 已在运行（PID {0}），跳过启动。" -f $pids) -ForegroundColor Green
  } else {
    Write-Host '启动 Worker…'
    $worker = Start-Process -FilePath $Venv -ArgumentList @('worker.py') `
      -WorkingDirectory $Srv -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $WorkerOut -RedirectStandardError $WorkerErr
    Start-Sleep -Seconds 2
    if ($worker.HasExited) {
      $tail = ''
      if (Test-Path -LiteralPath $WorkerErr) { $tail = (Get-Content -LiteralPath $WorkerErr -Tail 20 -Encoding UTF8) -join "`n" }
      throw "Worker 启动后立即退出。请查看日志：$WorkerErr`n$tail"
    }
    Write-Host ("Worker 已启动（PID {0}）" -f $worker.Id) -ForegroundColor Green
  }
}

try {
  if ($Stop) {
    Stop-All
    exit 0
  }
  if ($Restart) {
    Stop-All
    Start-All
  } elseif ($Status) {
    $healthy = Show-Status
    if (-not $healthy) { exit 1 }
  } else {
    Start-All
    Show-Status | Out-Null
  }
} catch {
  Write-Host ("[失败] " + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
