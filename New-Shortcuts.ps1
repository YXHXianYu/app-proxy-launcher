[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet('StartMenu', 'Desktop')][string[]]$Destination = @('StartMenu'),
    [string]$Directory,
    [string[]]$App
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.local.json' }
Import-Module (Join-Path $PSScriptRoot 'scripts\ProxyLauncher.psm1') -Force -DisableNameChecking
$config = Get-LauncherConfig -Path $ConfigPath
$selected = @($config.Apps | Where-Object { (Get-Setting $_ 'enabled' $true) -and (-not $App -or $_.id -in $App) })
if ($App) {
    foreach ($id in $App) {
        if ($id -notin @($selected.id)) { throw "Unknown or disabled app: $id" }
    }
}
if ($selected.Count -eq 0) { throw 'No enabled apps selected.' }
$directories = @()
if ($Directory) { $directories = @($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Directory)) }
else {
    foreach ($location in $Destination) {
        $base = if ($location -eq 'Desktop') { [Environment]::GetFolderPath('DesktopDirectory') }
                else { [Environment]::GetFolderPath('StartMenu') }
        if (-not $base) { throw "Cannot resolve $location for the current Windows user." }
        if ($location -eq 'StartMenu') { $directories += Join-Path $base 'Programs\App Proxy Launcher' }
        else { $directories += $base }
    }
}
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) { throw 'Windows PowerShell 5.1 was not found.' }
$launcher = Join-Path $PSScriptRoot 'Start-App.ps1'
$shell = New-Object -ComObject WScript.Shell
$pending = @()
# Validate every existing destination before writing any shortcuts.
foreach ($directoryPath in @($directories | Select-Object -Unique)) {
    foreach ($entry in $selected) {
        $name = [string](Get-Setting $entry 'name' $entry.id)
        $path = Join-Path $directoryPath ($name + '.lnk')
        $description = 'app_proxy_launcher:' + $entry.id
        if (Test-Path -LiteralPath $path) {
            $existing = $shell.CreateShortcut($path)
            if ($existing.Description -ne $description) { throw "An unrelated shortcut already exists; rename it before continuing: $path" }
        }
        $pending += [pscustomobject]@{ Path = $path; Description = $description; Entry = $entry }
    }
}
foreach ($item in $pending) {
    $parent = Split-Path -Parent $item.Path
    $null = New-Item -ItemType Directory -Path $parent -Force
    $link = $shell.CreateShortcut($item.Path)
    $link.TargetPath = $powerShellExe
    $tokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $launcher, '-App', $item.Entry.id, '-ConfigPath', $config.Path, '-Gui')
    $link.Arguments = (@($tokens | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $link.WorkingDirectory = $PSScriptRoot
    $link.Description = $item.Description
    $link.WindowStyle = 7
    $link.IconLocation = $powerShellExe + ',0'
    try {
        $plan = Get-AppLaunchPlan -Config $config -AppId $item.Entry.id
        $link.IconLocation = $plan.Executable + ',0'
    } catch {
        Write-Warning "Shortcut created without app icon for '$($item.Entry.id)': $($_.Exception.Message)"
    }
    $link.Save()
    Write-Output $item.Path
}
