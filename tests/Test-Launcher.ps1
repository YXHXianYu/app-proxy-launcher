[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\ProxyLauncher.psm1') -Force -DisableNameChecking
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $tempBase ('app_proxy_launcher_test_' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureRoot
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}
function Save-FixtureConfig {
    param($Value)
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:configPath -Encoding UTF8
    return Get-LauncherConfig -Path $script:configPath
}

$listener = $null
$waitingProbe = $null
$oldHttpProxy = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Process')
$oldMarker = [Environment]::GetEnvironmentVariable('APP_PROXY_LAUNCHER_TEST', 'Process')
try {
    $script:configPath = Join-Path $fixtureRoot 'config.local.test.json'
    $capturePath = Join-Path $fixtureRoot 'capture arguments.cs'
    $captureExe = Join-Path $fixtureRoot 'capture arguments.exe'
    $resultPath = Join-Path $fixtureRoot 'captured output.json'
    @'
using System;
using System.IO;
using System.Text;
public static class CaptureArguments {
    static string Quote(string value) {
        if (value == null) value = "";
        var text = new StringBuilder("\"");
        foreach (char c in value) {
            switch (c) {
                case '\\': text.Append("\\\\"); break;
                case '"': text.Append("\\\""); break;
                default:
                    if (c < 32) text.Append("\\u" + ((int)c).ToString("x4"));
                    else text.Append(c);
                    break;
            }
        }
        return text.Append('"').ToString();
    }
    public static void Main(string[] args) {
        var text = new StringBuilder("{\"args\":[");
        for (int i = 1; i < args.Length; i++) {
            if (i > 1) text.Append(',');
            text.Append(Quote(args[i]));
        }
        text.Append(']');
        foreach (string key in new[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY" }) {
            text.Append(',').Append(Quote(key)).Append(':').Append(Quote(Environment.GetEnvironmentVariable(key)));
        }
        text.Append(",\"marker\":").Append(Quote(Environment.GetEnvironmentVariable("APP_PROXY_LAUNCHER_TEST"))).Append('}');
        File.WriteAllText(args[0], text.ToString(), Encoding.Unicode);
        int waitMs;
        if (int.TryParse(Environment.GetEnvironmentVariable("APP_PROXY_LAUNCHER_WAIT_MS"), out waitMs)) System.Threading.Thread.Sleep(waitMs);
    }
}
'@ | Set-Content -LiteralPath $capturePath -Encoding ASCII
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    & $compiler /nologo /target:exe "/out:$captureExe" $capturePath
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the temporary .NET Framework argument-capture probe.' }
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $proxyUrl = 'http://127.0.0.1:' + $port
    $trickyArguments = @('space value', 'quote"value', 'C:\space path\', '中文参数', '')
    $data = [pscustomobject]@{
        version = 1
        proxy = [pscustomobject]@{ url = $proxyUrl; connectTimeoutMs = 300; noProxy = @('localhost', '127.0.0.1'); chromiumBypassList = 'localhost;127.0.0.1' }
        apps = @([pscustomobject]@{
            id = 'probe'; name = 'Probe (Proxy)'; enabled = $true
            executable = $captureExe
            strategy = 'both'; profileDirectory = '.\profile with spaces'
            preventMultipleInstances = $false
            arguments = (@($resultPath) + $trickyArguments)
            environment = [pscustomobject]@{ APP_PROXY_LAUNCHER_TEST = 'child:{proxyUrl}' }
        })
    }
    $config = Save-FixtureConfig $data
    Push-Location -LiteralPath $fixtureRoot
    try {
        $relativeConfig = Get-LauncherConfig -Path '.\config.local.test.json'
        Assert-True ($relativeConfig.Path -eq $configPath) 'relative ConfigPath follows PowerShell current directory'
    } finally { Pop-Location }
    Assert-True (Test-LauncherProxy $config) 'reachable local proxy endpoint'
    $plan = Get-AppLaunchPlan $config 'probe'
    Assert-True ($plan.ProfileDirectory -eq (Join-Path $fixtureRoot 'profile with spaces')) 'relative profile is resolved against config directory'
    Assert-True ($plan.Arguments -contains ('--proxy-server=' + $proxyUrl)) 'Chromium proxy argument included'
    Assert-True ($plan.Arguments -contains ('--user-data-dir=' + $plan.ProfileDirectory)) 'Chromium profile argument included'

    [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://parent.example:1234', 'Process')
    [Environment]::SetEnvironmentVariable('APP_PROXY_LAUNCHER_TEST', 'parent', 'Process')
    $process = Start-LauncherApp $plan
    Assert-True ($process.WaitForExit(10000)) 'child completes'
    Assert-True ($process.ExitCode -eq 0) 'child exits successfully'
    $captured = Get-Content -LiteralPath $resultPath -Raw -Encoding Unicode | ConvertFrom-Json
    foreach ($key in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
        Assert-True ($captured.$key -eq $proxyUrl) "$key reaches child"
    }
    Assert-True ($captured.NO_PROXY -eq 'localhost,127.0.0.1') 'NO_PROXY reaches child'
    Assert-True ($captured.marker -eq ('child:' + $proxyUrl)) 'custom child environment and proxy placeholder'
    Assert-True ([Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Process') -eq 'http://parent.example:1234') 'parent proxy unchanged'
    Assert-True ([Environment]::GetEnvironmentVariable('APP_PROXY_LAUNCHER_TEST', 'Process') -eq 'parent') 'parent custom environment unchanged'
    for ($i = 0; $i -lt $trickyArguments.Count; $i++) {
        Assert-True ($captured.args[$i] -ceq $trickyArguments[$i]) "argument round-trip at index $i"
    }
    Assert-True ($captured.args -contains ('--proxy-server=' + $proxyUrl)) 'actual child receives Chromium proxy argument'

    $waitingPlan = Get-AppLaunchPlan $config 'probe'
    $waitingPlan.Environment['APP_PROXY_LAUNCHER_WAIT_MS'] = '30000'
    $waitingProbe = Start-LauncherApp $waitingPlan
    $sameProfile = Get-AppLaunchPlan $config 'probe'
    Assert-True ($sameProfile.RunningProcessIds -contains $waitingProbe.Id) 'same explicit Chromium profile detected in actual running process'
    $otherData = $data | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $otherData.apps[0].profileDirectory = '.\other profile'
    $otherConfig = Save-FixtureConfig $otherData
    $otherProfile = Get-AppLaunchPlan $otherConfig 'probe'
    Assert-True ($otherProfile.RunningProcessIds -notcontains $waitingProbe.Id) 'another Chromium profile may run alongside this one'
    $waitingProbe.Kill()
    $waitingProbe.WaitForExit()
    $waitingProbe = $null

    $data.apps[0].strategy = 'chromium'
    $config = Save-FixtureConfig $data
    $process = Start-LauncherApp (Get-AppLaunchPlan $config 'probe')
    Assert-True ($process.WaitForExit(10000)) 'Chromium-only child completes'
    $captured = Get-Content -LiteralPath $resultPath -Raw -Encoding Unicode | ConvertFrom-Json
    Assert-True ($captured.HTTP_PROXY -eq '') 'Chromium-only child does not inherit parent HTTP_PROXY'
    Assert-True ($captured.args -contains ('--proxy-server=' + $proxyUrl)) 'Chromium-only proxy argument preserved'

    $data.apps[0].strategy = 'environment'
    $data.apps[0].profileDirectory = ''
    $config = Save-FixtureConfig $data
    $plan = Get-AppLaunchPlan $config 'probe'
    Assert-True (-not (@($plan.Arguments) -match '^--proxy-')) 'environment strategy adds no Chromium flags'
    $plan.PreventMultipleInstances = $true
    $plan.RunningProcessIds = @($PID)
    Assert-Throws { Start-LauncherApp $plan } 'existing instance blocks launch without killing it'

    $checkData = $data | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $checkOutput = Join-Path $fixtureRoot 'must_not_be_created.json'
    $checkData.apps[0].arguments = @($checkOutput)
    $null = Save-FixtureConfig $checkData
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $checkText = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Start-App.ps1') -App probe -ConfigPath $configPath -CheckOnly 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "CheckOnly succeeds: $($checkText -join ' ')"
    Assert-True (-not (Test-Path -LiteralPath $checkOutput)) 'CheckOnly does not launch configured executable'

    $config = Save-FixtureConfig $data
    $shortcutDir = Join-Path $fixtureRoot 'shortcuts with spaces'
    $null = & (Join-Path $root 'New-Shortcuts.ps1') -ConfigPath $configPath -Directory $shortcutDir
    $shortcutPath = Join-Path $shortcutDir 'Probe (Proxy).lnk'
    Assert-True (Test-Path -LiteralPath $shortcutPath) 'shortcut generated'
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcutPath)
    Assert-True ($link.TargetPath -ieq $windowsPowerShell) 'shortcut uses Windows PowerShell'
    Assert-True ($link.Arguments.Contains('Start-App.ps1') -and $link.Arguments.Contains($configPath) -and $link.Arguments.Contains('-Gui')) 'shortcut references launcher, local config, and GUI errors'
    $null = & (Join-Path $root 'New-Shortcuts.ps1') -ConfigPath $configPath -Directory $shortcutDir
    Assert-True (Test-Path -LiteralPath $shortcutPath) 'shortcut regeneration is idempotent'
    $link.Description = 'unrelated user shortcut'
    $link.Save()
    Assert-Throws { & (Join-Path $root 'New-Shortcuts.ps1') -ConfigPath $configPath -Directory $shortcutDir } 'unrelated shortcut is preserved'

    $initPath = Join-Path $fixtureRoot 'config.local.initialized.json'
    $null = & (Join-Path $root 'Initialize.ps1') -ConfigPath $initPath -NoShortcuts
    Assert-True (Test-Path -LiteralPath $initPath) 'Initialize copies template'
    '{"keep":"existing configuration"}' | Set-Content -LiteralPath $initPath -Encoding UTF8
    $before = Get-Content -LiteralPath $initPath -Raw
    $null = & (Join-Path $root 'Initialize.ps1') -ConfigPath $initPath -NoShortcuts
    Assert-True ((Get-Content -LiteralPath $initPath -Raw) -ceq $before) 'Initialize never overwrites machine config'

    $standalone = Join-Path $fixtureRoot 'standalone repository'
    $null = New-Item -ItemType Directory -Path $standalone
    foreach ($name in @('Initialize.ps1', 'template.config.json', 'Start-App.ps1', 'Test-Configuration.ps1', 'New-Shortcuts.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $standalone
    }
    Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination $standalone -Recurse
    $initText = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $standalone 'Initialize.ps1') -NoShortcuts 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "standalone Initialize resolves its default config path: $($initText -join ' ')"
    $defaultConfigPath = Join-Path $standalone 'config.local.json'
    Assert-True (Test-Path -LiteralPath $defaultConfigPath) 'default config is created next to the script'
    $checkData | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $defaultConfigPath -Encoding UTF8
    $defaultCheckText = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $standalone 'Start-App.ps1') -App probe -CheckOnly 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "standalone Start-App resolves its default config path: $($defaultCheckText -join ' ')"
    $defaultTestText = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $standalone 'Test-Configuration.ps1') 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "standalone Test-Configuration resolves its default config path: $($defaultTestText -join ' ')"
    $defaultShortcuts = Join-Path $fixtureRoot 'default config shortcuts'
    $defaultShortcutText = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $standalone 'New-Shortcuts.ps1') -Directory $defaultShortcuts 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "standalone New-Shortcuts resolves its default config path: $($defaultShortcutText -join ' ')"
    Assert-True (Test-Path -LiteralPath (Join-Path $defaultShortcuts 'Probe (Proxy).lnk')) 'default-config shortcut actually exists'

    Assert-Throws { Get-AppLaunchPlan $config 'unknown' } 'unknown app rejected'
    $data.apps[0].enabled = $false
    $config = Save-FixtureConfig $data
    Assert-Throws { Get-AppLaunchPlan $config 'probe' } 'disabled app rejected'
    $data.apps[0].enabled = $true
    $data.apps += $data.apps[0]
    Assert-Throws { Save-FixtureConfig $data } 'duplicate app id rejected'
    $data.apps = @($data.apps[0])
    $data.apps[0].strategy = 'transparent_magic'
    Assert-Throws { Save-FixtureConfig $data } 'unknown proxy strategy rejected'
    $data.apps[0].strategy = 'environment'
    $data.proxy.url = 'http://user:password@127.0.0.1:7890'
    Assert-Throws { Save-FixtureConfig $data } 'credentials are not leaked into command-line arguments'
    $data.proxy.url = 'socks5://127.0.0.1:7891'
    Assert-Throws { Save-FixtureConfig $data } 'SOCKS-only port is not mislabeled as an HTTP proxy'
    $data.proxy.url = $proxyUrl
    $data.apps[0].enabled = 'false'
    Assert-Throws { Save-FixtureConfig $data } 'string boolean rejected'
    $data.apps[0].enabled = $true
    $data.apps[0].executable = '.\missing.exe'
    $config = Save-FixtureConfig $data
    Assert-Throws { Get-AppLaunchPlan $config 'probe' } 'missing executable rejected'
    $listener.Stop()
    $listener = $null
    Assert-True (-not (Test-LauncherProxy $config)) 'unreachable endpoint reported'
    Write-Output "PASS: $script:passed assertions on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    if ($null -ne $waitingProbe -and -not $waitingProbe.HasExited) { $waitingProbe.Kill(); $waitingProbe.WaitForExit() }
    if ($null -ne $listener) { $listener.Stop() }
    [Environment]::SetEnvironmentVariable('HTTP_PROXY', $oldHttpProxy, 'Process')
    [Environment]::SetEnvironmentVariable('APP_PROXY_LAUNCHER_TEST', $oldMarker, 'Process')
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if ($resolvedFixture.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedFixture) -like 'app_proxy_launcher_test_*') {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
