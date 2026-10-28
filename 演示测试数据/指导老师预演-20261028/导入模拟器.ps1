param(
  [string]$HdcPath = 'D:\DevEco\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
  [string[]]$Target
)
$ErrorActionPreference = 'Stop'
# Only adds this package's fictional materials; never resets an app or removes data.
if (-not (Test-Path -LiteralPath $HdcPath)) { throw "找不到 hdc：$HdcPath，请用 -HdcPath 指定实际路径。" }
function Invoke-Hdc([string[]]$Arguments) {
  $output = & $HdcPath @Arguments 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $output -match '\[Fail\]|\[Error\]') { throw $output }
  return $output.Trim()
}
$connected = @((Invoke-Hdc @('list','targets')) -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '[Empty]' })
if ($connected.Count -eq 0) { throw '没有在线设备。请在设备管理器点击手机/平板的运行按钮，等到鸿蒙桌面出现后再执行。' }
if (-not $Target) {
  $Target = @($connected | Where-Object { $_ -match '^127\.0\.0\.1:\d+$' })
  if ($Target.Count -eq 0) { throw "未发现本机模拟器。在线设备：$($connected -join ', ')。请用 -Target 明确选择。" }
}
$report = @()
foreach ($device in $Target) {
  if ($device -notin $connected) { throw "设备不在线：$device" }
  $deviceType = Invoke-Hdc @('-t',$device,'shell','param get const.product.devicetype')
  if ($deviceType -match '^(2in1|pc|tv|wearable)$') { Write-Host "跳过非手机/平板设备 $device ($deviceType)"; continue }
  Write-Host "导入 $device ($deviceType)"
  $downloads = $null
  foreach ($candidate in @('/storage/Users/currentUser/Download','/storage/Users/currentUser/Downloads','/storage/media/100/local/files/Download','/storage/media/100/local/files/Downloads')) {
    $found = Invoke-Hdc @('-t',$device,'shell',"if [ -d '$candidate' ]; then echo ZHIXUE_EXISTS; fi")
    if ($found -match 'ZHIXUE_EXISTS') { $downloads = $candidate; break }
  }
  if (-not $downloads) { throw "设备 $device 的用户下载目录未识别，尚未写入。请先核对该系统的文件管理路径。" }
  $remote = "$downloads/ZhixueDemo20261028"
  Invoke-Hdc @('-t',$device,'shell',"mkdir -p '$remote'") | Write-Host
  $verifiedFiles = @()
  $photos = @()
  foreach ($folder in @('01-图片','02-课程与DDL','03-上传讲义')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -File) {
      $destination = "$remote/$($file.Name)"
      Invoke-Hdc @('-t',$device,'file','send',$file.FullName,$destination) | Write-Host
      $size = Invoke-Hdc @('-t',$device,'shell',"stat -c %s '$destination'")
      if ($size.Trim() -ne [string]$file.Length) { throw "大小校验失败：$destination ($size / $($file.Length))" }
      $verifiedFiles += @{ name=$file.Name; bytes=$file.Length; remote=$destination }
      if ($file.Extension -eq '.png') {
        # mediatool registers photos in the gallery; -urf preserves our source file.
        $existing = ''
        try { $existing = Invoke-Hdc @('-t',$device,'shell',"mediatool query -u '$($file.Name)'") } catch { Write-Host "相册尚未查到 $($file.Name)，尝试登记。" }
        if ($existing -notmatch 'file://media/Photo/') {
          Invoke-Hdc @('-t',$device,'shell',"mediatool send '$destination' -urf") | Write-Host
        }
        $registered = Invoke-Hdc @('-t',$device,'shell',"mediatool query -u '$($file.Name)'")
        if ($registered -notmatch 'file://media/Photo/') { throw "照片已复制，但相册注册未确认：$($file.Name)。请检查 mediatool 权限。" }
        $photos += @{name=$file.Name; query=$registered}
      }
    }
  }
  $report += @{target=$device; deviceType=$deviceType; directory=$remote; fileCount=$verifiedFiles.Count; files=$verifiedFiles; galleryCount=$photos.Count; gallery=$photos; checkedAt=(Get-Date).ToString('o'); pickerManuallyVerified=$false}
  Write-Host "完成 $device：文件 $($verifiedFiles.Count) 份，相册图片 $($photos.Count) 张。请在应用文件/图片选择器中再次确认可选。"
}
if ($report.Count -eq 0) { throw '没有导入任何手机或平板设备。' }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $PSScriptRoot '模拟器导入结果.json') -Encoding utf8
Write-Host '导入结果已写入本文件夹的 模拟器导入结果.json。'
