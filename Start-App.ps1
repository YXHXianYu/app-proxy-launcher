[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$App,
    [string]$ConfigPath,
    [switch]$CheckOnly,
    [switch]$Gui
)

$ErrorActionPreference = 'Stop'
try {
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.local.json' }
    Import-Module (Join-Path $PSScriptRoot 'scripts\ProxyLauncher.psm1') -Force -DisableNameChecking
    $config = Get-LauncherConfig -Path $ConfigPath
    $plan = Get-AppLaunchPlan -Config $config -AppId $App
    if (-not (Test-LauncherProxy -Config $config)) {
        throw "Proxy TCP endpoint is unreachable: $($config.ProxyUrl). Start Mihomo/Clash, or correct proxy.url."
    }
    if ($CheckOnly) {
        [pscustomobject]@{
            App = $plan.AppId; Executable = $plan.Executable; Strategy = $plan.Strategy
            Proxy = $plan.ProxyUrl; ProxyTcpReachable = $true
            Arguments = $plan.Arguments; ProfileDirectory = $plan.ProfileDirectory
            AlreadyRunning = ($plan.RunningProcessIds.Count -gt 0)
            WouldBlockLaunch = ($plan.PreventMultipleInstances -and $plan.RunningProcessIds.Count -gt 0)
        } | Format-List
    } else {
        $started = Start-LauncherApp -Plan $plan
        Write-Output "Started '$App' with proxy $($plan.ProxyUrl) (PID: $($started.Id))."
    }
} catch {
    if ($Gui) {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'App Proxy Launcher', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } else { Write-Error -Message $_.Exception.Message -ErrorAction Continue }
    exit 1
}
