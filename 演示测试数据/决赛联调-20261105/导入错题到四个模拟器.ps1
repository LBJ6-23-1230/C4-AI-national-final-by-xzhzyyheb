param(
  [string]$HdcPath = 'D:\DevEco\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
  [string]$EmulatorPath = 'D:\DevEco\DevEco Studio\tools\emulator\Emulator.exe',
  [string[]]$Names = @('Pura 90', 'Mate X7', 'MatePad Pro 13', 'MateBook Pro'),
  [switch]$KeepRunning,
  [switch]$SkipStart,
  [switch]$SkipStop,
  [switch]$ShowWindow,
  [int]$BootTimeoutSeconds = 900
)

$Names = @($Names |
  ForEach-Object { $_ -split '[,，、]' } |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ })


$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$ImageRoot = Join-Path $Root '错题'
$ReportPath = Join-Path $Root '导入结果-错题.json'

foreach ($tool in @($HdcPath, $EmulatorPath)) {
  if (-not (Test-Path -LiteralPath $tool)) {
    throw "找不到工具：$tool。请用 -HdcPath / -EmulatorPath 指定实际路径。"
  }
}

function Invoke-Hdc {
  param([string[]]$Arguments)
  $output = & $HdcPath @Arguments 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $output -match '\[Fail\]|\[Error\]') {
    throw ($output.Trim())
  }
  return $output.Trim()
}

function Get-Targets {
  $raw = & $HdcPath list targets 2>&1 | Out-String
  return @($raw -split '\r?\n' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -ne '[Empty]' })
}

function Start-Emulator {
  param([string]$Name)
  $window = if ($ShowWindow) { 'Normal' } else { 'Minimized' }
  Start-Process -FilePath $EmulatorPath -ArgumentList @('-start', "`"$Name`"") -WindowStyle $window
}

function Stop-Emulator {
  param([string]$Name)
  Start-Process -FilePath $EmulatorPath -ArgumentList @('-stop', "`"$Name`"") -WindowStyle Hidden -Wait
}

function Test-DeviceShell {
  param([string]$Device)
  try {
    $probe = Invoke-Hdc @('-t', $Device, 'shell', 'echo ZHIXUE_READY')
    return ($probe -match 'ZHIXUE_READY')
  } catch {
    return $false
  }
}

function Wait-ForDevice {
  param([int]$TimeoutSeconds)
  $start = Get-Date
  $deadline = $start.AddSeconds($TimeoutSeconds)
  $lastNotice = $start
  while ((Get-Date) -lt $deadline) {
    foreach ($target in @(Get-Targets)) {
      if (Test-DeviceShell -Device $target) { return @($target) }
    }
    if (((Get-Date) - $lastNotice).TotalSeconds -ge 30) {
      Write-Host ("    等待设备就绪… 已用 {0:N0}s" -f ((Get-Date) - $start).TotalSeconds)
      $lastNotice = Get-Date
    }
    Start-Sleep -Seconds 4
  }
  throw "等待设备超时（${TimeoutSeconds}s）。若模拟器窗口显示 Emulator Freeze，请关闭后重试，或手动启动后用 -SkipStart。"
}

function Wait-UntilOffline {
  param([int]$TimeoutSeconds = 90)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (@(Get-Targets).Count -eq 0) { return $true }
    Start-Sleep -Seconds 3
  }
  return $false
}

function Unlock-Device {
  param([string]$Device)
  try { Invoke-Hdc @('-t', $Device, 'shell', 'power-shell wakeup') | Out-Null } catch { }
  Start-Sleep -Seconds 1
  $screen = ''
  try { $screen = Invoke-Hdc @('-t', $Device, 'shell', 'hidumper -s RenderService -a screen') } catch { }
  $match = [regex]::Match($screen, 'resolution=(\d+)x(\d+)')
  if (-not $match.Success) { return }
  $width = [int]$match.Groups[1].Value
  $height = [int]$match.Groups[2].Value
  $x = [int]($width / 2)
  $y1 = [int]($height * 0.82)
  $y2 = [int]($height * 0.30)
  try {
    Invoke-Hdc @('-t', $Device, 'shell', "uitest uiInput swipe $x $y1 $x $y2 400") | Out-Null
  } catch { }
  Start-Sleep -Seconds 2
}

function Find-MediaAlbum {
  param([string]$Device)
  $root = '/mnt/data/100/media_fuse/Photo'
  $listing = ''
  try { $listing = Invoke-Hdc @('-t', $Device, 'shell', "ls -1 '$root' 2>/dev/null") } catch { }
  $dirs = @($listing -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($dirs.Count -eq 0) { return $null }
  $ordered = @()
  if ($dirs -contains '其它') { $ordered += '其它' }
  $ordered += ($dirs | Where-Object { $_ -ne '其它' })
  foreach ($dir in $ordered) {
    $candidate = "$root/$dir"
    try {
      $probe = Invoke-Hdc @('-t', $Device, 'shell', "if [ -d '$candidate' ]; then echo ZHIXUE_EXISTS; fi")
      if ($probe -match 'ZHIXUE_EXISTS') { return $candidate }
    } catch { }
  }
  return $null
}

$ImageFiles = @(Get-ChildItem -LiteralPath $ImageRoot -File -Filter '*.png' -ErrorAction SilentlyContinue)
if ($ImageFiles.Count -eq 0) { throw "没有找到错题图片：$ImageRoot" }

Write-Host ''
Write-Host '=== 知学 Mate · 错题导入四台模拟器 ===' -ForegroundColor Cyan
Write-Host ("错题目录：{0}" -f $ImageRoot)
Write-Host ("图片：{0} 张；目标：{1}" -f $ImageFiles.Count, ($Names -join '、'))
Write-Host ''

$report = @()
$errors = @()

foreach ($name in $Names) {
  $startedHere = $false
  $entry = [ordered]@{
    name = $name
    target = $null
    deviceType = $null
    model = $null
    albumDirectory = $null
    imageCount = 0
    images = @()
    galleryCount = 0
    gallery = @()
    appInstalled = $null
    startedByScript = $false
    error = $null
    checkedAt = (Get-Date).ToString('o')
  }

  try {
    Write-Host ("--- {0} ---" -f $name) -ForegroundColor Cyan
    $targets = @(Get-Targets)
    if ($targets.Count -eq 0) {
      if ($SkipStart) { throw '当前没有在线设备，且指定了 -SkipStart。' }
      Write-Host '  启动模拟器（冷启动可能 3–10 分钟）…'
      Start-Emulator -Name $name
      $startedHere = $true
      $entry.startedByScript = $true
      $targets = @(Wait-ForDevice -TimeoutSeconds $BootTimeoutSeconds)
    } elseif (-not (Test-DeviceShell -Device $targets[0])) {
      Write-Host '  设备已出现但 shell 未就绪，继续等待…'
      $targets = @(Wait-ForDevice -TimeoutSeconds 120)
    }
    if ($targets.Count -gt 1) {
      throw "检测到多台在线设备：$($targets -join ', ')。请只保留一台，或先手动关闭其余模拟器。"
    }

    $device = $targets[0]
    $entry.target = $device
    Write-Host ("  设备：{0}" -f $device)

    $deviceType = (Invoke-Hdc @('-t', $device, 'shell', 'param get const.product.devicetype')).Trim()
    $entry.deviceType = $deviceType
    try {
      $entry.model = (Invoke-Hdc @('-t', $device, 'shell', 'param get const.product.model')).Trim()
    } catch { }

    Write-Host '  唤醒并解锁（相册目录需要解锁后才挂载）…'
    $album = Find-MediaAlbum -Device $device
    if (-not $album) {
      Unlock-Device -Device $device
      $album = Find-MediaAlbum -Device $device
    }
    if (-not $album) {
      Start-Sleep -Seconds 10
      $album = Find-MediaAlbum -Device $device
    }
    if (-not $album) {
      throw '未找到 MediaLibrary 相册目录（/mnt/data/100/media_fuse/Photo）。请先在模拟器里打开一次「图库」，解锁屏幕后重试。'
    }
    $entry.albumDirectory = $album
    Write-Host ("  相册目录：{0}" -f $album)

    foreach ($file in $ImageFiles) {
      $destination = "$album/$($file.Name)"
      try { Invoke-Hdc @('-t', $device, 'shell', "rm -f '$destination'") | Out-Null } catch { }
      Invoke-Hdc @('-t', $device, 'file', 'send', $file.FullName, $destination) | Out-Null
      $size = (Invoke-Hdc @('-t', $device, 'shell', "stat -c %s '$destination'")).Trim()
      if ($size -ne [string]$file.Length) {
        throw "大小校验失败：$($file.Name)（设备 $size / 本地 $($file.Length)）"
      }
      $entry.images += [ordered]@{ name = $file.Name; bytes = $file.Length; remote = $destination }
      $entry.imageCount++
    }
    Invoke-Hdc @('-t', $device, 'shell', 'sync') | Out-Null
    Start-Sleep -Seconds 1
    Write-Host ("  已写入相册文件：{0} 张并 sync，等待媒体库索引…" -f $entry.imageCount) -ForegroundColor Green

    foreach ($file in $ImageFiles) {
      $query = ''
      for ($attempt = 1; $attempt -le 10; $attempt++) {
        try { $query = Invoke-Hdc @('-t', $device, 'shell', "mediatool query -u '$($file.Name)'") } catch { }
        if ($query -match 'file://media/Photo/') { break }
        Start-Sleep -Seconds 2
      }
      if ($query -notmatch 'file://media/Photo/') {
        throw "图片已写入相册目录，但媒体库未索引：$($file.Name)。请在模拟器打开一次「图库」后重试。"
      }

      $uriMatch = [regex]::Match($query, 'file://media/Photo/[^"\r\n]+')
      if (-not $uriMatch.Success) { throw "媒体库返回的 URI 无法解析：$($file.Name)" }
      $checkPath = "/data/local/tmp/zhixue_check_$($file.Name)"
      try { Invoke-Hdc @('-t', $device, 'shell', "rm -f '$checkPath'") | Out-Null } catch { }
      Invoke-Hdc @('-t', $device, 'shell', "mediatool recv '$($uriMatch.Value)' '$checkPath'") | Out-Null
      $recvSize = (Invoke-Hdc @('-t', $device, 'shell', "stat -c %s '$checkPath'")).Trim()
      if ($recvSize -ne [string]$file.Length) {
        throw "媒体库回读大小不一致：$($file.Name)（回读 $recvSize / 本地 $($file.Length)）"
      }
      try { Invoke-Hdc @('-t', $device, 'shell', "rm -f '$checkPath'") | Out-Null } catch { }
      $entry.gallery += [ordered]@{ name = $file.Name; query = $query; recvBytes = [int]$recvSize }
      $entry.galleryCount++
    }
    Write-Host ("  媒体库已索引并回读校验：{0} 张" -f $entry.galleryCount) -ForegroundColor Green

    try {
      $bundle = Invoke-Hdc @('-t', $device, 'shell', 'bm dump -n com.zhixue.mate')
      $entry.appInstalled = ($bundle -match 'com\.zhixue\.mate')
    } catch {
      $entry.appInstalled = $false
    }
    Write-Host ("  应用已安装：{0}" -f $entry.appInstalled)
  } catch {
    $entry.error = $_.Exception.Message
    $errors += [ordered]@{ name = $name; message = $entry.error }
    Write-Host ("  [失败] {0}" -f $entry.error) -ForegroundColor Red
  } finally {
    $report += $entry
    if ($startedHere -and -not $KeepRunning -and -not $SkipStop) {
      Write-Host '  关闭模拟器…'
      try {
        Stop-Emulator -Name $name
        if (-not (Wait-UntilOffline)) {
          Write-Host '  [警告] 模拟器未在 90s 内离线，请手动确认。' -ForegroundColor Yellow
        }
      } catch {
        Write-Host ("  [警告] 关闭模拟器失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
      }
    }
    Write-Host ''
  }
}

$mergedDevices = @()
if (Test-Path -LiteralPath $ReportPath) {
  try {
    $previous = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($old in @($previous.devices)) {
      if ($old -and ($Names -notcontains $old.name)) { $mergedDevices += $old }
    }
  } catch {
    Write-Host ("  [提示] 旧结果读取失败，将只写本次设备：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
  }
}
$mergedDevices += $report

$result = [ordered]@{
  generatedAt = (Get-Date).ToString('o')
  imageDirectory = $ImageRoot
  sourceImageCount = $ImageFiles.Count
  requestedNames = $Names
  completed = ($errors.Count -eq 0)
  errors = $errors
  devices = $mergedDevices
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8

Write-Host '=== 汇总 ===' -ForegroundColor Cyan
foreach ($item in $report) {
  $state = if ($item.error) { '失败' } else { '成功' }
  Write-Host ("  {0,-18} {1,-24} 图片 {2} 张，索引 {3} 张，{4}" -f $item.name, $item.target, $item.imageCount, $item.galleryCount, $state)
}
Write-Host ''
Write-Host ("结果已写入：{0}" -f $ReportPath)
if ($errors.Count -gt 0) {
  Write-Host ("有 {0} 台设备导入失败，见上面的错误信息。" -f $errors.Count) -ForegroundColor Red
  exit 1
}
