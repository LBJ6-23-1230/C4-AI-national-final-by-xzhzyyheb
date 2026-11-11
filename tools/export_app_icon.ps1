param([string]$Master = "$PSScriptRoot/../outputs/app-icon-20261107/zhixue-mate-master.png")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$source = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Master).Path)
try {
    if ($source.Width -ne $source.Height) { throw 'The icon master must be square.' }
    foreach ($size in @(32, 48, 64, 128, 256, 512, 1024)) {
        $bitmap = [System.Drawing.Bitmap]::new($size, $size)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($source, 0, 0, $size, $size)
            $output = Join-Path $root "outputs/app-icon-20261107/zhixue-mate-$size.png"
            $bitmap.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { $source.Dispose() }
foreach ($scope in @('app/AppScope', 'app/entry/src/main')) {
    Copy-Item -LiteralPath (Join-Path $root 'outputs/app-icon-20261107/zhixue-mate-512.png') -Destination (Join-Path $root "$scope/resources/base/media/zhixue_icon.png")
}
Write-Output 'Exported 32–1024 px previews and identical 512 px application/module resources.'
