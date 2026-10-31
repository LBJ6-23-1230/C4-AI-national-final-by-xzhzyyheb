param(
    [string]$Target = '127.0.0.1:5555',
    [string]$Name = 'feedback3-current',
    [int]$ClickX = -1,
    [int]$ClickY = -1,
    [switch]$Back,
    [string]$Hdc = 'D:/DevEco/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe'
)
$ErrorActionPreference = 'Stop'
if ($Name -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Use a plain filename label' }
$taskRoot = Split-Path $PSScriptRoot -Parent
if ($Back) {
    & $Hdc -t $Target shell uitest uiInput keyEvent Back
} elseif ($ClickX -ge 0 -and $ClickY -ge 0) {
    & $Hdc -t $Target shell uitest uiInput click $ClickX $ClickY
}
& $Hdc -t $Target shell uitest dumpLayout -p "/data/local/tmp/$Name.json"
& $Hdc -t $Target file recv "/data/local/tmp/$Name.json" (Join-Path $taskRoot ".local-work/$Name.json")
& $Hdc -t $Target shell uitest screenCap -p "/data/local/tmp/$Name.png"
& $Hdc -t $Target file recv "/data/local/tmp/$Name.png" (Join-Path $taskRoot "evidence/$Name.png")
