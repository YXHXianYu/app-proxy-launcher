[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$SkipProxyCheck
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.local.json' }
Import-Module (Join-Path $PSScriptRoot 'scripts\ProxyLauncher.psm1') -Force -DisableNameChecking
$config = Get-LauncherConfig -Path $ConfigPath
$failed = $false
Write-Output "Configuration: $($config.Path)"
if (-not $SkipProxyCheck) {
    if (Test-LauncherProxy -Config $config) { Write-Output "[OK] Proxy TCP endpoint reachable: $($config.ProxyUrl) (not an Internet connectivity test)." }
    else { Write-Output "[FAIL] Proxy TCP endpoint unreachable: $($config.ProxyUrl)"; $failed = $true }
}
foreach ($app in $config.Apps) {
    if (-not (Get-Setting $app 'enabled' $true)) { continue }
    try {
        $plan = Get-AppLaunchPlan -Config $config -AppId $app.id
        Write-Output "[OK] $($plan.AppId): $($plan.Executable) [$($plan.Strategy)]"
        if ($plan.PreventMultipleInstances -and $plan.RunningProcessIds.Count -gt 0) {
            Write-Output '     Already running. Fully exit this app before starting it through its proxy shortcut.'
        }
        if ($plan.ProfileDirectory) { Write-Output "     Profile: $($plan.ProfileDirectory)" }
    } catch { Write-Output "[FAIL] $($app.id): $($_.Exception.Message)"; $failed = $true }
}
if ($failed) { exit 1 }
