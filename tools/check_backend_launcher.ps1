$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'start-all.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  Invoke-Expression $definition.Extent.Text
}
$Port = 5000
$Srv = Join-Path $root 'server\zhixue-agent-server'
$Venv = Join-Path $Srv '.venv\Scripts\python.exe'
$NoWorker = $true
$NoDeviceBridge = $true
$WithReminders = $false
$script:stopped = @()
$script:listeners = @()
$script:inspectionFails = $false
$script:managed = @{}
function Get-NetTCPConnection {
  param($State, $ErrorAction)
  if ($script:inspectionFails) { throw 'inspection denied' }
  $script:listeners
}
function Get-ProjectApiProcess {
  param([int]$ProcessId)
  $script:managed[$ProcessId]
}
function Stop-ProcessTree {
  param([int]$ProcessId)
  $script:stopped += $ProcessId
}
function Start-Sleep { param($Seconds) }
function Assert-Launcher {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}
function Assert-Throws {
  param([scriptblock]$Action)
  $caught = $false
  try { & $Action | Out-Null } catch { $caught = $true }
  Assert-Launcher $caught 'Expected a safe failure.'
}
Assert-Launcher ((Get-ApiPid) -eq 0) 'An unused port must be reported as unused.'
$script:inspectionFails = $true
Assert-Throws { Get-ApiPid }
$script:inspectionFails = $false
$script:listeners = @(
  [pscustomobject]@{ LocalPort = 5000; OwningProcess = 101 },
  [pscustomobject]@{ LocalPort = 5000; OwningProcess = 101 },
  [pscustomobject]@{ LocalPort = 6000; OwningProcess = 999 }
)
Assert-Launcher ((Get-ApiPid) -eq 101) 'IPv4 and IPv6 rows must not create duplicate processes.'
$script:listeners += [pscustomobject]@{ LocalPort = 5000; OwningProcess = 102 }
Assert-Throws { Get-ApiPid }
$script:managed[101] = [pscustomobject]@{ ProcessId = 201 }
$script:managed[102] = [pscustomobject]@{ ProcessId = 202 }
Stop-All | Out-Null
Assert-Launcher (($script:stopped -join ',') -eq '201,202') 'Stop must handle all verified project listeners.'
$script:stopped = @()
$script:managed.Remove(102)
Assert-Throws { Stop-All }
Assert-Launcher ($script:stopped.Count -eq 0) 'An unrelated listener must abort before stopping anything.'
$script:managed[102] = $script:managed[101]
Stop-All | Out-Null
Assert-Launcher (($script:stopped -join ',') -eq '201') 'A shared launcher must only be stopped once.'
$ownWorker = [pscustomobject]@{ CommandLine = ('"{0}" "{1}"' -f $Venv, (Join-Path $Srv 'worker.py')) }
Assert-Launcher (Test-ProjectCommand $ownWorker 'worker.py') 'The exact project worker must match.'
$relativeWorker = [pscustomobject]@{ CommandLine = ('"{0}" worker.py' -f $Venv) }
Assert-Launcher (Test-ProjectCommand $relativeWorker 'worker.py') 'The project venv launcher must match.'
$otherWorker = [pscustomobject]@{ CommandLine = '"C:\other\python.exe" worker.py' }
Assert-Launcher (-not (Test-ProjectCommand $otherWorker 'worker.py')) 'Other projects must not match.'
$extraArgument = [pscustomobject]@{ CommandLine = ('"{0}" worker.py --other-task' -f $Venv) }
Assert-Launcher (-not (Test-ProjectCommand $extraArgument 'worker.py')) 'Different worker invocations must not match.'
Write-Host 'PASS backend launcher: inspection failures, duplicate listeners, verified stops and project isolation.'
