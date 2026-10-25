# app_proxy_launcher

在 Windows 上通过快捷方式，单独让指定应用使用 Mihomo / Clash 的本地 HTTP 代理。无需开启系统代理或 TUN；游戏及登录器可继续交给 UU 等游戏加速器。

这是一个无第三方依赖的 PowerShell 脚本仓库。跨机器复用的是脚本和配置模板，每台电脑单独保存 `config.local.json`。本项目不包含订阅、节点、密码或加速器配置，也不修改系统代理、注册表、全局环境变量或已有快捷方式。

## 快速开始

需要 Windows 10/11、Windows PowerShell 5.1（系统自带）、Mihomo / Clash 已运行，并提供 HTTP 或 mixed 代理端口。PowerShell 7 也可用于手动执行；生成的快捷方式固定使用系统 PowerShell 5.1。

在仓库目录打开 PowerShell：

```powershell
# 创建被 Git 忽略的本机配置，生成开始菜单和桌面快捷方式。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Initialize.ps1 -Desktop

# 检查代理端口以及本机应用路径；不会启动或关闭应用。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Configuration.ps1
```

默认启用 Chrome 和 Codex。先编辑 `config.local.json`：如果某个应用未安装，将其 `enabled` 改为 `false`。端口与本机不同则修改 `proxy.url`。再次运行 `Initialize.ps1` 会保留已有配置；更改应用名称或启用状态后可运行 `New-Shortcuts.ps1` 生成快捷方式。

只创建配置，不创建快捷方式：

```powershell
.\Initialize.ps1 -NoShortcuts
```

另一台电脑上 clone 仓库，再执行同样命令即可。不需要复制第一台电脑的配置，也不用改脚本里的用户名或盘符。不要把本机配置改名为普通的 `config.json`；`config.local*.json` 才是约定并被忽略的文件名。

## 日常使用

1. 启动 Mihomo / Clash。系统代理、PAC 和 TUN 可以保持关闭。
2. 首次切换启动方式前，完全退出目标应用，包括托盘和后台进程。Chrome 默认复用原有数据目录，因此需要先完全退出所有 Chrome 窗口和后台进程。脚本不会强制终止进程。
3. 从开始菜单的 **App Proxy Launcher** 文件夹或桌面的代理快捷方式打开应用。

快捷方式会隐藏启动脚本窗口；缺少应用、配置错误、代理端口不可达、原应用仍在运行时，会弹出错误提示。检查端口只证明 TCP 可连接，不证明代理协议、节点或互联网连接可用。可在 Mihomo 的连接列表中验证真实请求。

手动启动或只检查：

```powershell
.\Start-App.ps1 -App chrome
.\Start-App.ps1 -App codex -CheckOnly
.\Test-Configuration.ps1 -SkipProxyCheck  # 离线时仅检查配置与应用路径
```

不会改变已经运行的应用的代理。更新配置后，需要退出应用并通过快捷方式重新启动。

## Chrome 与 Codex 的默认行为

**Chrome**：自动寻找注册的 Chrome 路径及常见安装目录，添加 `--proxy-server`。默认将 `profileDirectory` 设置为空字符串，复用 Chrome 原有的默认用户数据目录，继续使用原有账号登录状态、书签、扩展和设置，不创建独立配置。本工具不会导入、复制或删除浏览器数据。

完全退出所有 Chrome 后，从代理快捷方式启动。同一实例后续打开的窗口也使用这套代理，包括从普通快捷方式或游戏登录器打开的网页。若要恢复普通启动，需完全退出 Chrome，再从原快捷方式打开。若以后需要分离浏览器数据，可将 `profileDirectory` 改为 `%LOCALAPPDATA%\AppProxyLauncher\Chrome`；这时原有 Chrome 可以与专用代理实例并行运行。

**Codex**：通过当前用户的 `OpenAI.Codex` 商店包自动寻找 `app\ChatGPT.exe` 或 `app\Codex.exe`，不硬编码带版本号的 WindowsApps 目录。默认 `both`，设置进程环境变量并添加 Chromium 代理参数；Codex 数据目录保持原样。应用更新后如果目录结构改变，可在配置中显式指定 `executable`。当前运行的 Codex 不会被重启或关闭。

注意：代理启动器不能强制接管不支持代理的网络组件，也不会接管所有 UDP、WebRTC、DNS 或外部工具连接。子程序可能继承环境变量；是否使用它们取决于子程序的实现。外部浏览器登录遵循该浏览器的代理配置。应用级代理可减少与 UU 的交叉，但不能保证与 UU 的所有加速项目都兼容。

## 配置说明

模板：`template.config.json` → 本机文件：`config.local.json`，JSON 不支持注释。

| 字段 | 说明 |
| --- | --- |
| `version` | 固定为 `1` |
| `proxy.url` | 如 `http://127.0.0.1:7890`，支持 HTTP/HTTPS 代理，不支持凭据、路径或 SOCKS URL |
| `proxy.noProxy` | 传给环境变量 `NO_PROXY` 的数组 |
| `proxy.chromiumBypassList` | Chromium 绕过列表，以分号分隔 |
| `proxy.connectTimeoutMs` | 代理端口连接超时，100–30000 毫秒 |
| `apps[].id` | 唯一应用 ID，小写字母开头，后续可含数字、下划线 |
| `apps[].name` | 快捷方式名称，不含 `.lnk`，不允许文件名非法字符 |
| `apps[].enabled` | JSON 布尔值，控制是否允许启动和生成快捷方式 |
| `apps[].autoDetect` | 可省略；内置 `chrome`、`codex` |
| `apps[].executable` | 显式 `.exe` 路径；非空时优先于自动发现 |
| `apps[].strategy` | `environment`、`chromium` 或 `both` |
| `apps[].arguments` | 原样传给应用的字符串数组，每个参数单独一项，不要手动加用于包裹整个参数的引号 |
| `apps[].environment` | 额外的进程环境变量对象，不要在这里重复代理变量 |
| `apps[].workingDirectory` | 可省略，默认是可执行文件所在目录 |
| `apps[].profileDirectory` | 仅 Chromium 策略支持；空字符串表示使用应用原有数据目录 |
| `apps[].preventMultipleInstances` | 默认 `true`；检测同一可执行文件是否运行；指定 Chromium 数据目录时只阻止相同目录的实例，无法确定目录时保守阻止 |

路径支持 `%LOCALAPPDATA%`、`%APPDATA%`、`%USERPROFILE%`、`%ProgramFiles%` 等 Windows 环境变量，不能写 PowerShell 的 `$env:...`。相对路径基于**配置文件所在目录**。`arguments`、`environment` 还支持 `{proxyUrl}` 替换。配置可以放在其他位置，并使用 `-ConfigPath` 指定。

### 三种代理策略

- `environment`：只给子进程设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY`；适合明确支持这些变量的程序。Windows 环境变量名不区分大小写。
- `chromium`：增加 `--proxy-server`、`--proxy-bypass-list`，可指定 `--user-data-dir`；适合 Chrome。子进程中会移除继承的代理环境变量，避免干扰显式参数。
- `both`：同时使用以上两种方式；适合需要同时处理 Chromium 前端和后台联网组件的 Electron 应用。并非所有 Electron 应用都接受相同参数，需按应用实际行为验证。

不能仅凭添加环境变量就代理任意软件。若应用不支持上述任何方式，需要使用该应用原生的代理选项或另行考虑其他方案。这里不会启用 TUN 或注入网络驱动。

### 添加一个应用

复制模板中的 `example_app` 项，修改为实际配置并启用，例如一个支持代理环境变量的程序：

```json
{
  "id": "my_app",
  "name": "My App (Proxy)",
  "enabled": true,
  "executable": "%LOCALAPPDATA%\\Programs\\MyApp\\MyApp.exe",
  "strategy": "environment",
  "preventMultipleInstances": true,
  "arguments": [],
  "environment": {}
}
```

如果应用只支持自己的代理参数，可以通过 `arguments` 写入，例如 `["--proxy", "{proxyUrl}"]`；具体参数应查询该应用文档，不要照搬示例。对于有意允许多个独立实例的程序，可将 `preventMultipleInstances` 设置为 `false`；应先确认旧进程不会接收并忽略新的代理设置。

## 快捷方式管理

```powershell
.\New-Shortcuts.ps1                       # 开始菜单
.\New-Shortcuts.ps1 -Destination Desktop  # 桌面
.\New-Shortcuts.ps1 -Destination StartMenu,Desktop
.\New-Shortcuts.ps1 -App chrome           # 只生成某一个应用
.\New-Shortcuts.ps1 -Directory 'D:\My Shortcuts'
```

生成器只覆盖有本工具管理标记的同名快捷方式，遇到其他同名快捷方式会报错并保留它。未安装的应用仍可生成快捷方式，启动时显示如何修复；生成器会提示无法提取图标。

快捷方式指向仓库中的脚本，并显式记录本机配置路径，所以移动仓库或更换配置位置后应重新生成。禁用应用或改名不会自动删除旧快捷方式；旧快捷方式启动禁用应用时会报错，可手动删除不再需要的条目。程序的后台脚本策略参数只作用于该次 PowerShell 进程，不会永久修改执行策略；组织策略仍可能禁止执行。

## Git 与验证

```powershell
git init -b main                         # 新目录首次建立仓库；已初始化的目录无需重复
git status --short
git check-ignore config.local.json      # 应输出 config.local.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Launcher.ps1
```

自动化测试使用本机临时目录、回环 TCP 监听，以及 Windows 自带 .NET Framework 编译器生成的临时参数捕获程序，验证真实子进程中的环境变量、参数转义、实例保护、只检查不启动、快捷方式生成及配置保护，不依赖外网或第三方测试包。测试不会启动 Chrome/Codex，不修改系统代理，不结束已有应用；临时目录在测试后清理。

参考：[Chromium 代理参数](https://www.chromium.org/developers/design-documents/network-settings/)、[Chromium 独立用户目录](https://www.chromium.org/developers/creating-and-using-profiles/)。
