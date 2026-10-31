param(
    [string]$ExpectedAddress = '10.77.203.46',
    [int]$Port = 5432
)
# Run on the Windows computer hosting PostgreSQL. Read-only; no passwords.
$ErrorActionPreference = 'Stop'
$taskErrors = [System.Collections.Generic.List[string]]::new()
$taskAddresses = @()
$taskServices = @()
$taskListeners = @()
$taskConfigs = @()
$taskFirewall = @()
try {
    $taskAddresses = @(Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object InterfaceAlias,IPAddress,PrefixLength)
} catch { $taskErrors.Add('IPv4 inspection: ' + $_.Exception.GetType().Name) }
try {
    $taskServiceObjects = @(Get-CimInstance Win32_Service |
        Where-Object { $_.Name -match 'postgres' -or $_.DisplayName -match 'PostgreSQL' })
    $taskServices = @($taskServiceObjects | Select-Object Name,State,ProcessId,StartMode)
    foreach ($taskService in $taskServiceObjects) {
        $taskMatch = [regex]::Match($taskService.PathName, '(?i)(?:^|\s)-D\s+(?:"(?<quoted>[^"]+)"|(?<plain>\S+))')
        if (-not $taskMatch.Success) { continue }
        $taskDataPath = if ($taskMatch.Groups['quoted'].Success) { $taskMatch.Groups['quoted'].Value } else { $taskMatch.Groups['plain'].Value }
        foreach ($taskFileName in @('postgresql.conf', 'postgresql.auto.conf')) {
            $taskConfigPath = Join-Path $taskDataPath $taskFileName
            if (-not (Test-Path -LiteralPath $taskConfigPath)) { continue }
            # Only emit selected network settings; never dump entire config files.
            $taskSettings = @(Get-Content -LiteralPath $taskConfigPath | ForEach-Object {
                if ($_ -match '^\s*(listen_addresses|port|ssl|max_connections)\s*=\s*([^#]+)') {
                    [pscustomobject]@{ Setting=$Matches[1]; Value=$Matches[2].Trim() }
                }
            })
            $taskConfigs += [pscustomobject]@{ File=$taskConfigPath; ExplicitNetworkSettings=$taskSettings }
        }
    }
} catch { $taskErrors.Add('Service/config inspection: ' + $_.Exception.GetType().Name) }
try {
    $taskListeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object LocalAddress,LocalPort,OwningProcess)
} catch { $taskErrors.Add('Listener inspection: ' + $_.Exception.GetType().Name) }
try {
    $taskFirewall = @(Get-NetFirewallProfile |
        Select-Object Name,Enabled,DefaultInboundAction)
} catch { $taskErrors.Add('Firewall inspection needs elevated PowerShell or is unavailable') }
$taskFindings = [System.Collections.Generic.List[string]]::new()
if ($taskAddresses.Count -gt 0 -and $ExpectedAddress -notin $taskAddresses.IPAddress) {
    $taskFindings.Add('EXPECTED_IP_NOT_ASSIGNED: the configured address is not currently assigned to this computer. Verify DHCP/IP changes before editing the client.')
}
if ($taskServices.Count -eq 0) { $taskFindings.Add('NO_POSTGRESQL_WINDOWS_SERVICE_FOUND: confirm how PostgreSQL is started (service/container/manual).') }
elseif (@($taskServices | Where-Object State -eq 'Running').Count -eq 0) { $taskFindings.Add('POSTGRESQL_SERVICE_NOT_RUNNING') }
if ($taskListeners.Count -eq 0) { $taskFindings.Add('NO_LISTENER_ON_DATABASE_PORT') }
elseif (@($taskListeners | Where-Object { $_.LocalAddress -notin @('127.0.0.1','::1') }).Count -eq 0) {
    $taskFindings.Add('LOOPBACK_ONLY_LISTENER: remote computers cannot use this binding.')
}
if ($taskFindings.Count -eq 0) {
    $taskFindings.Add('Host address and listener need no obvious correction. Next verify the process is PostgreSQL, local psql login, firewall allow rules, pg_hba.conf, and client isolation on the network.')
}
[pscustomobject]@{
    ComputerName=$env:COMPUTERNAME
    ExpectedDatabaseAddress=$ExpectedAddress
    Port=$Port
    IPv4=$taskAddresses
    PostgreSQLServices=$taskServices
    Listeners=$taskListeners
    ConfigFiles=$taskConfigs
    FirewallProfiles=$taskFirewall
    Findings=@($taskFindings)
    InspectionErrors=@($taskErrors)
    Note='Read-only. Settings in included config files and command-line overrides may differ; active values should be verified with SHOW after a successful local login.'
} | ConvertTo-Json -Depth 7
