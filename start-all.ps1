param(
  [ValidateRange(1, 65535)][int]$Port = 5000,
  [switch]$Stop,
  [switch]$Status,
  [switch]$Restart,
  [switch]$NoWorker,
  [switch]$WithReminders,
  [switch]$NoDeviceBridge,
  [string]$HdcPath = '',
  [string]$DeviceId = ''
)


$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Srv = Join-Path $Root 'server\zhixue-agent-server'
$Venv = Join-Path $Srv '.venv\Scripts\python.exe'
$LogDir = Join-Path $Root 'logs'
$ApiOut = Join-Path $LogDir "api-$Port.log"
$ApiErr = Join-Path $LogDir "api-$Port.err.log"
$BridgeScript = Join-Path $Root 'tools\device_bridge.py'
$BridgeState = Join-Path $LogDir "device-bridge-$Port.json"

if (-not (Test-Path -LiteralPath $Venv)) {
  throw "找不到虚拟环境：$Venv`n请先在 server\zhixue-agent-server 下创建 .venv 并安装依赖。"
}

function Get-ApiPids {
  Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq $Port } |
    Select-Object -ExpandProperty OwningProcess -Unique
}

function Get-ApiPid {
  $listeners = @(Get-ApiPids)
  if ($listeners.Count -gt 1) { throw "端口 $Port 存在多个监听进程，请先检查占用。" }
  if ($listeners.Count -eq 1) { return [int]$listeners[0] }
  return 0
}

function Test-ProjectCommand {
  param($Process, [string]$Script, [string]$Arguments = '\s*$')
  if (-not $Process -or -not $Process.CommandLine) { return $false }
  $python = [regex]::Escape($Venv)
  $absolute = [regex]::Escape($(if ([IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $Srv $Script }))
  $relative = [regex]::Escape($Script)
  return ($Process.CommandLine -match ('^\s*"?{0}"?\s+"?(?:{1}|{2})"?{3}' -f $python, $absolute, $relative, $Arguments))
}

function Get-ProjectApiProcess {
  param([int]$ProcessId)
  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if (-not $process) { return }
  $arguments = "(?:\s+--quiet)?\s+--port\s+`"?$Port`"?(?:\s+--quiet)?\s*$"
  if ($Port -eq 5000) { $arguments = "(?:$arguments|(?:\s+--quiet)?\s*$)" }
  $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ParentProcessId)" -ErrorAction SilentlyContinue
  if ((Test-ProjectCommand $parent 'run.py' $arguments) -and
      $process.Name -eq 'python.exe' -and $parent.CreationDate -le $process.CreationDate) { return $parent }
  if (Test-ProjectCommand $process 'run.py' $arguments) { return $process }
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
  param([string]$Script)
  $all = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction Stop)
  $matched = @($all | Where-Object { Test-ProjectCommand $_ $Script })
  return $matched | Where-Object { $_.ParentProcessId -notin $matched.ProcessId }
}

function Get-BridgeProcesses {
  $all = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction Stop)
  $matched = @($all | Where-Object {
    (Test-ProjectCommand $_ $BridgeScript '\s+--hdc\s+') -and
    $_.CommandLine -match "\s--port\s+$Port(?:\s|$)"
  })
  return $matched | Where-Object { $_.ParentProcessId -notin $matched.ProcessId }
}

function Start-DeviceBridge {
  if ($NoDeviceBridge) { return }
  if (@(Get-BridgeProcesses).Count -gt 0) { Write-Host 'USB 自动恢复已在运行。'; return }
  $resolvedHdc = $HdcPath
  if (-not $resolvedHdc) {
    $command = Get-Command hdc.exe -ErrorAction SilentlyContinue
    if ($command) { $resolvedHdc = $command.Source }
  }
  if (-not $resolvedHdc) {
    $candidates = @('D:\develop\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
      'D:\DevEco\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe')
    if ($env:DEVECO_SDK_HOME) { $candidates += Join-Path $env:DEVECO_SDK_HOME 'default\openharmony\toolchains\hdc.exe' }
    $resolvedHdc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  }
  if (-not $resolvedHdc -or -not (Test-Path -LiteralPath $resolvedHdc)) {
    Write-Host '未找到 HDC，USB 自动恢复未启用；可用 -HdcPath 指定。' -ForegroundColor Yellow
    return
  }
  $bridgeArguments = @(('"' + $BridgeScript + '"'), '--hdc', ('"' + $resolvedHdc + '"'),
    '--port', "$Port", '--state', ('"' + $BridgeState + '"'))
  if ($DeviceId) { $bridgeArguments += @('--device', $DeviceId) }
  $bridge = Start-Process -FilePath $Venv -ArgumentList $bridgeArguments -WorkingDirectory $Root `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $LogDir "device-bridge-$Port.log") `
    -RedirectStandardError (Join-Path $LogDir "device-bridge-$Port.err.log")
  Start-Sleep -Seconds 1
  if ($bridge.HasExited) { throw 'USB 自动恢复进程启动失败，请检查 device-bridge 日志。' }
  Write-Host 'USB 自动恢复已启动，设备重新连接后会自动恢复后端转发。' -ForegroundColor Green
}

function Stop-ProcessTree {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return }
  try {
    & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
      throw "无法停止 PID $ProcessId"
    }
  } catch {
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
  }
}

function Show-Status {
  $apiPid = Get-ApiPid
  $ready = $false
  $managedApi = $false
  if ($apiPid -gt 0) {
    $managedApi = $null -ne (Get-ProjectApiProcess $apiPid)
    if ($managedApi) { $ready = Test-Ready }
  }
  $workers = @(Get-WorkerProcesses 'worker.py')
  $reminderWorkers = @(Get-WorkerProcesses 'reminder_worker.py')
  $bridges = @(Get-BridgeProcesses)

  Write-Host ''
  Write-Host '=== 知学 Mate 后端状态 ===' -ForegroundColor Cyan
  if ($apiPid -gt 0) {
    $state = if (-not $managedApi) { '端口由其他进程占用' } elseif ($ready) { '/ready 200（仓储可用）' } else { '/ready 不通' }
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
  if ($reminderWorkers.Count) {
    Write-Host ("  提醒 Worker : 运行中  PID {0}" -f ($reminderWorkers.ProcessId -join ', '))
  } else {
    Write-Host '  提醒 Worker : 未运行（未检查系统通知）'
  }
  Write-Host ("  日志   : {0}" -f $LogDir)
  if ($bridges.Count) {
    Write-Host '  USB    : 自动恢复运行中；设备连接状态见 device-bridge 日志' -ForegroundColor Green
  } else { Write-Host '  USB    : 自动恢复未运行' -ForegroundColor Yellow }
  Write-Host ''
  return ($ready -and ($workers.Count -gt 0 -or $NoWorker) -and ($reminderWorkers.Count -gt 0 -or -not $WithReminders))
}

function Stop-All {
  $managedApis = @()
  foreach ($apiPid in @(Get-ApiPids)) {
    $managed = Get-ProjectApiProcess $apiPid
    if (-not $managed) { throw "端口 $Port 由非本项目进程占用（PID $apiPid）。请改用其他端口。" }
    $managedApis += $managed
  }
  $managedApis = @($managedApis | Sort-Object ProcessId -Unique)
  $workers = @()
  if (-not $NoWorker) { $workers += @(Get-WorkerProcesses 'worker.py') }
  if (-not $NoWorker -or $WithReminders) { $workers += @(Get-WorkerProcesses 'reminder_worker.py') }
  if (-not $NoDeviceBridge) { $workers += @(Get-BridgeProcesses) }
  Write-Host ''
  Write-Host '=== 停止后端 ===' -ForegroundColor Cyan
  if ($managedApis.Count -gt 0) {
    foreach ($managed in $managedApis) {
      Stop-ProcessTree -ProcessId $managed.ProcessId
      Write-Host ("  API 已停止（PID {0}）" -f $managed.ProcessId) -ForegroundColor Green
    }
  } else {
    Write-Host '  API 本来就没运行' -ForegroundColor Yellow
  }
  foreach ($worker in $workers) {
    Stop-ProcessTree -ProcessId $worker.ProcessId
    Write-Host ("  Worker 已停止（PID {0}）" -f $worker.ProcessId) -ForegroundColor Green
  }
  if ($NoWorker -and -not $WithReminders) {
    Write-Host '  仅处理 API，保留已有 Worker。'
  } elseif ($workers.Count -eq 0) {
    Write-Host '  本次未找到要停止的 Worker' -ForegroundColor Yellow
  }
  Start-Sleep -Seconds 2
  Write-Host ''
}

function Start-ManagedWorker {
  param([string]$Script, [string]$Label)
  $workers = @(Get-WorkerProcesses $Script)
  if ($workers.Count -gt 0) {
    Write-Host ("$Label 已在运行（PID {0}），跳过启动。" -f ($workers.ProcessId -join ', ')) -ForegroundColor Green
    return
  }
  $stem = [IO.Path]::GetFileNameWithoutExtension($Script)
  $outLog = Join-Path $LogDir "$stem.log"
  $errLog = Join-Path $LogDir "$stem.err.log"
  $entry = Join-Path $Srv $Script
  $worker = Start-Process -FilePath $Venv -ArgumentList @('"' + $entry + '"') `
    -WorkingDirectory $Srv -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog
  Start-Sleep -Seconds 2
  if ($worker.HasExited) { throw "$Label 启动后退出。请查看日志：$errLog" }
  Write-Host ("$Label 已启动（PID {0}）" -f $worker.Id) -ForegroundColor Green
}

function Start-All {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  $env:PYTHONIOENCODING = 'utf-8'

  $apiPid = Get-ApiPid
  if ($apiPid -gt 0) {
    if (-not (Get-ProjectApiProcess $apiPid)) {
      throw "端口 $Port 由非本项目进程占用（PID $apiPid）。请改用其他端口。"
    }
    if (-not (Test-Ready)) {
      throw "端口 $Port 已被 PID $apiPid 占用，但 /ready 不通。请先 .\start-all.ps1 -Stop，或检查日志：$ApiErr"
    }
    Write-Host ("API 已在运行（PID {0}），跳过启动。" -f $apiPid) -ForegroundColor Green
  } else {
    Write-Host '启动 API…'
    $entry = Join-Path $Srv 'run.py'
    $api = Start-Process -FilePath $Venv -ArgumentList @(('"' + $entry + '"'), '--port', "$Port") `
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

  if (-not $NoWorker) { Start-ManagedWorker 'worker.py' 'Worker' }
  if ($WithReminders) { Start-ManagedWorker 'reminder_worker.py' '提醒 Worker' }
  Start-DeviceBridge
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
    exit 0
  } else {
    Start-All
  }
  if (-not (Show-Status)) { exit 1 }
} catch {
  Write-Host ("[失败] " + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
