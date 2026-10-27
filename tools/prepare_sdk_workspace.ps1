param([string]$DevEcoHome = 'D:/DevEco/DevEco Studio')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskSource = Join-Path $DevEcoHome 'sdk/default'
$taskTarget = Join-Path $taskRoot '.local-work/sdk-build-isolated/default'
if (-not (Test-Path -LiteralPath (Join-Path $taskSource 'sdk-pkg.json'))) {
    throw 'SDK metadata not found; choose the installed DevEcoHome.'
}
# No deletion or mutation of the installed SDK. Large immutable components are
# junctions; executable toolchains are copies inside this workspace.
New-Item -ItemType Directory -Force -Path $taskTarget | Out-Null
Copy-Item -LiteralPath (Join-Path $taskSource 'sdk-pkg.json') -Destination (Join-Path $taskTarget 'sdk-pkg.json')
foreach ($taskPlatform in @('hms', 'openharmony')) {
    $taskPlatformTarget = Join-Path $taskTarget $taskPlatform
    New-Item -ItemType Directory -Force -Path $taskPlatformTarget | Out-Null
    foreach ($taskComponent in Get-ChildItem -LiteralPath (Join-Path $taskSource $taskPlatform)) {
        $taskComponentTarget = Join-Path $taskPlatformTarget $taskComponent.Name
        if (Test-Path -LiteralPath $taskComponentTarget) { continue }
        if ($taskComponent.Name -eq 'toolchains') {
            Copy-Item -LiteralPath $taskComponent.FullName -Destination $taskComponentTarget -Recurse
        } elseif ($taskComponent.PSIsContainer) {
            New-Item -ItemType Junction -Path $taskComponentTarget -Target $taskComponent.FullName | Out-Null
        } else {
            Copy-Item -LiteralPath $taskComponent.FullName -Destination $taskComponentTarget
        }
    }
}
$taskPreviewLibraries = Join-Path $taskSource 'openharmony/previewer/common/bin/*.dll'
Copy-Item -Path $taskPreviewLibraries -Destination (Join-Path $taskTarget 'openharmony/toolchains')
Copy-Item -Path (Join-Path $taskSource 'hms/toolchains/lib/*.dll') -Destination (Join-Path $taskTarget 'openharmony/toolchains')
Write-Output (Split-Path $taskTarget -Parent)
