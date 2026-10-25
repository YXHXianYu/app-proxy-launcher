[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Desktop,
    [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.local.json' }
$ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
# Keep machine configuration ignored even when choosing a custom filename.
if ([IO.Path]::GetFileName($ConfigPath) -notlike 'config.local*.json') {
    throw 'Use a filename matching config.local*.json so the machine configuration is ignored by Git.'
}
if (Test-Path -LiteralPath $ConfigPath) {
    Write-Output "Keeping existing configuration: $ConfigPath"
} else {
    $parent = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Configuration directory does not exist: $parent" }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'template.config.json') -Destination $ConfigPath
    Write-Output "Created machine configuration: $ConfigPath"
}
if (-not $NoShortcuts) {
    $destinations = @('StartMenu')
    if ($Desktop) { $destinations += 'Desktop' }
    & (Join-Path $PSScriptRoot 'New-Shortcuts.ps1') -ConfigPath $ConfigPath -Destination $destinations
}
Write-Output 'Ready. Edit config.local.json as needed; run Test-Configuration.ps1 to check apps and the proxy endpoint.'
