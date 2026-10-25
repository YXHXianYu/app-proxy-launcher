Set-StrictMode -Version 2.0

function Get-Setting {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-BooleanSetting {
    param($Object, [string]$Name, [bool]$Default)
    $value = Get-Setting $Object $Name $Default
    if ($value -isnot [bool]) { throw "'$Name' must be a JSON boolean (true/false)." }
    return $value
}

function Expand-LauncherText {
    param([string]$Text, [string]$ProxyUrl)
    return [Environment]::ExpandEnvironmentVariables($Text).Replace('{proxyUrl}', $ProxyUrl)
}

function Resolve-LauncherPath {
    param([string]$Path, [string]$Root, [string]$ProxyUrl = '')
    $expanded = Expand-LauncherText $Path $ProxyUrl
    if ($expanded -match '%[^%]+%') { throw "Unresolved environment variable in path: $Path" }
    if (-not [IO.Path]::IsPathRooted($expanded)) { $expanded = Join-Path $Root $expanded }
    return [IO.Path]::GetFullPath($expanded)
}

function Get-LauncherConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Configuration not found: $resolved. Run Initialize.ps1 first."
    }
    try { $data = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Cannot read JSON configuration '$resolved': $($_.Exception.Message)" }
    if ((Get-Setting $data 'version') -ne 1) { throw 'Unsupported configuration version; expected version: 1.' }
    $proxy = Get-Setting $data 'proxy'
    $url = [Environment]::ExpandEnvironmentVariables([string](Get-Setting $proxy 'url' ''))
    $uri = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or -not $uri.Host -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
        throw 'proxy.url must be an HTTP(S) proxy URL without credentials, path, query, or fragment; e.g. http://127.0.0.1:7890.'
    }
    $timeout = Get-Setting $proxy 'connectTimeoutMs' 1500
    if ($timeout -isnot [int] -and $timeout -isnot [long]) { throw 'connectTimeoutMs must be an integer.' }
    if ($timeout -lt 100 -or $timeout -gt 30000) { throw 'connectTimeoutMs must be between 100 and 30000.' }
    $apps = @(Get-Setting $data 'apps' @())
    if ($apps.Count -eq 0) { throw 'Configure at least one app.' }
    $ids = @{}
    $names = @{}
    foreach ($app in $apps) {
        $id = [string](Get-Setting $app 'id' '')
        if ($id -cnotmatch '^[a-z][a-z0-9_]*$') { throw "Invalid app id '$id'; use lowercase letters, numbers, and underscores." }
        if ($ids.ContainsKey($id)) { throw "Duplicate app id: $id" }
        $ids[$id] = $true
        $enabled = Get-BooleanSetting $app 'enabled' $true
        $null = Get-BooleanSetting $app 'preventMultipleInstances' $true
        $strategy = [string](Get-Setting $app 'strategy' 'environment')
        if ($strategy -notin @('environment', 'chromium', 'both')) { throw "Invalid strategy for '$id': $strategy" }
        if ([string](Get-Setting $app 'autoDetect' '') -notin @('', 'chrome', 'codex')) { throw "Unknown autoDetect for '$id'." }
        if (-not (Get-Setting $app 'executable' '') -and -not (Get-Setting $app 'autoDetect' '')) {
            throw "Set executable or autoDetect for '$id'."
        }
        foreach ($argument in @(Get-Setting $app 'arguments' @())) {
            if ($argument -isnot [string]) { throw "arguments for '$id' must be an array of strings." }
            if ($strategy -in @('chromium', 'both') -and $argument -match '^--(proxy-server|proxy-pac-url|proxy-auto-detect|no-proxy-server|proxy-bypass-list|user-data-dir)(=|$)') {
                throw "Do not duplicate managed Chromium proxy/profile arguments for '$id'."
            }
        }
        $environment = Get-Setting $app 'environment'
        if ($null -ne $environment) {
            if ($environment -isnot [pscustomobject]) { throw "environment for '$id' must be a JSON object." }
            foreach ($entry in $environment.PSObject.Properties) {
                if ($entry.Value -isnot [string] -or $entry.Name -match '[=\x00]') { throw "Invalid environment entry for '$id'." }
                if ($entry.Name -match '^(?i:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)$') { throw "Set proxy settings in proxy, not in apps.environment ($id)." }
            }
        }
        $name = [string](Get-Setting $app 'name' $id)
        if ([string]::IsNullOrWhiteSpace($name) -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name.TrimEnd(' ', '.') -ne $name) {
            throw "Invalid shortcut name for '$id'."
        }
        if ($enabled -and $names.ContainsKey($name)) { throw "Duplicate shortcut name: $name" }
        if ($enabled) { $names[$name] = $true }
    }
    return [pscustomobject]@{
        Data = $data; Path = $resolved; Root = Split-Path -Parent $resolved
        ProxyUrl = $uri.AbsoluteUri.TrimEnd('/'); ProxyUri = $uri
        ConnectTimeoutMs = [int]$timeout; Apps = $apps
    }
}

function Resolve-AppExecutable {
    param($App, $Config)
    $explicit = [string](Get-Setting $App 'executable' '')
    $candidates = @()
    if ($explicit) {
        $candidates = @(Resolve-LauncherPath $explicit $Config.Root $Config.ProxyUrl)
    } else {
        switch ([string](Get-Setting $App 'autoDetect' '')) {
            'chrome' {
                foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
                    $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
                    if ($null -ne $item) {
                        $registered = Get-Setting $item '(default)' ''
                        if ($registered) { $candidates += $registered }
                    }
                }
                foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
                    if ($base) { $candidates += Join-Path $base 'Google\Chrome\Application\chrome.exe' }
                }
            }
            'codex' {
                if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
                    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
                    foreach ($package in $packages) {
                        foreach ($relative in @('app\ChatGPT.exe', 'app\Codex.exe')) {
                            $candidates += Join-Path $package.InstallLocation $relative
                        }
                    }
                }
            }
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $result = [IO.Path]::GetFullPath($candidate)
            if ([IO.Path]::GetExtension($result) -ine '.exe') { throw "Executable must be an .exe file: $result" }
            return $result
        }
    }
    throw "Cannot locate '$($App.id)'. Install it, set its executable in config.local.json, or disable it."
}

function Get-RunningAppIds {
    param([string]$Executable, [string]$ProfileDirectory)
    $processName = [IO.Path]::GetFileNameWithoutExtension($Executable)
    foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        try { $runningPath = $process.Path } catch { $runningPath = $null }
        if ($runningPath -and -not [string]::Equals($runningPath, $Executable, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($ProfileDirectory) {
            try {
                $info = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
                $commandLine = [string]$info.CommandLine
            } catch { $commandLine = '' }
            if ($commandLine) {
                $pattern = '(?:^|\s)(?:"--user-data-dir=(?<whole>[^\"]*)"|--user-data-dir=(?:"(?<assigned>[^\"]*)"|(?<bare>\S+))|--user-data-dir\s+(?:"(?<separate>[^\"]*)"|(?<separateBare>\S+)))'
                $match = [regex]::Match($commandLine, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                # An instance using the default profile cannot own our explicit profile.
                if (-not $match.Success) { continue }
                $runningProfile = ''
                foreach ($group in @('whole', 'assigned', 'bare', 'separate', 'separateBare')) {
                    if ($match.Groups[$group].Success) { $runningProfile = $match.Groups[$group].Value; break }
                }
                if ([IO.Path]::IsPathRooted($runningProfile)) {
                    try {
                        $normalized = [IO.Path]::GetFullPath($runningProfile).TrimEnd([char[]]'\/')
                        if (-not [string]::Equals($normalized, $ProfileDirectory.TrimEnd([char[]]'\/'), [StringComparison]::OrdinalIgnoreCase)) { continue }
                    } catch { }
                }
            }
            # Unknown command line/profile: conservatively block rather than reuse it.
        }
        $process.Id
    }
}

function Get-AppLaunchPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$AppId)
    $matches = @($Config.Apps | Where-Object { $_.id -eq $AppId })
    if ($matches.Count -ne 1) { throw "Unknown app '$AppId'. Available ids: $(($Config.Apps.id) -join ', ')" }
    $app = $matches[0]
    if (-not (Get-BooleanSetting $app 'enabled' $true)) { throw "App '$AppId' is disabled in the configuration." }
    $executable = Resolve-AppExecutable $app $Config
    $strategy = [string](Get-Setting $app 'strategy' 'environment')
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in @(Get-Setting $app 'arguments' @())) {
        $arguments.Add((Expand-LauncherText $argument $Config.ProxyUrl))
    }
    $profile = [string](Get-Setting $app 'profileDirectory' '')
    if ($profile) {
        if ($strategy -eq 'environment') { throw "profileDirectory requires chromium or both strategy ($AppId)." }
        $profile = Resolve-LauncherPath $profile $Config.Root $Config.ProxyUrl
    }
    if ($strategy -in @('chromium', 'both')) {
        $arguments.Add('--proxy-server=' + $Config.ProxyUrl)
        $bypass = [string](Get-Setting (Get-Setting $Config.Data 'proxy') 'chromiumBypassList' '<local>;localhost;127.0.0.1;[::1]')
        if ($bypass) { $arguments.Add('--proxy-bypass-list=' + $bypass) }
        if ($profile) { $arguments.Add('--user-data-dir=' + $profile) }
    }
    $environment = @{}
    $custom = Get-Setting $app 'environment'
    if ($null -ne $custom) {
        foreach ($entry in $custom.PSObject.Properties) {
            $environment[$entry.Name] = Expand-LauncherText $entry.Value $Config.ProxyUrl
        }
    }
    # Remove inherited global proxies even for Chromium-only applications.
    foreach ($key in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) { $environment[$key] = $null }
    if ($strategy -in @('environment', 'both')) {
        foreach ($key in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) { $environment[$key] = $Config.ProxyUrl }
        $environment['NO_PROXY'] = (@(Get-Setting (Get-Setting $Config.Data 'proxy') 'noProxy' @('localhost', '127.0.0.1', '::1')) -join ',')
    }
    $workingDirectory = [string](Get-Setting $app 'workingDirectory' '')
    if ($workingDirectory) { $workingDirectory = Resolve-LauncherPath $workingDirectory $Config.Root $Config.ProxyUrl }
    else { $workingDirectory = Split-Path -Parent $executable }
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) { throw "Working directory does not exist: $workingDirectory" }
    $runningIds = @(Get-RunningAppIds -Executable $executable -ProfileDirectory $profile)
    return [pscustomobject]@{
        AppId = $AppId; Name = [string](Get-Setting $app 'name' $AppId)
        Executable = $executable; Arguments = $arguments.ToArray(); Strategy = $strategy
        ProfileDirectory = $profile; WorkingDirectory = $workingDirectory
        Environment = $environment; ProxyUrl = $Config.ProxyUrl
        PreventMultipleInstances = Get-BooleanSetting $app 'preventMultipleInstances' $true
        RunningProcessIds = $runningIds
    }
}

function Test-LauncherProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)
    $client = New-Object Net.Sockets.TcpClient
    $async = $null
    try {
        $async = $client.BeginConnect($Config.ProxyUri.DnsSafeHost, $Config.ProxyUri.Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($Config.ConnectTimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    } catch { return $false }
    finally {
        if ($null -ne $async) { $async.AsyncWaitHandle.Close() }
        $client.Close()
    }
}

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)
    # CommandLineToArgvW/CRT escaping, including quotes and trailing backslashes.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-LauncherApp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)
    if ($Plan.PreventMultipleInstances -and $Plan.RunningProcessIds.Count -gt 0) {
        throw "'$($Plan.AppId)' is already running (PID: $($Plan.RunningProcessIds -join ', ')). Fully exit it, including its tray/background processes, then use the proxy shortcut. No process was terminated."
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Plan.Executable
    $startInfo.WorkingDirectory = $Plan.WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = (@($Plan.Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    foreach ($key in $Plan.Environment.Keys) {
        if ($null -eq $Plan.Environment[$key]) { $startInfo.EnvironmentVariables.Remove($key) }
        else { $startInfo.EnvironmentVariables[$key] = [string]$Plan.Environment[$key] }
    }
    return [Diagnostics.Process]::Start($startInfo)
}

Export-ModuleMember -Function Get-Setting, Get-LauncherConfig, Get-AppLaunchPlan, Test-LauncherProxy, ConvertTo-WindowsArgument, Start-LauncherApp
