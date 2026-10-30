<#
.SYNOPSIS
    可选的登录自启动代理守护：开机/登录时消除"死代理"窗口。

.DESCRIPTION
    解决的问题：代理客户端在关机时被系统直接结束，来不及把系统代理关掉，
    于是下次开机后、客户端启动前，所有走系统代理的程序都会连向一个不存在的端口。

    本脚本在每次登录时执行三步：
      1. 若系统代理开着但端口无人监听 → 立即关闭（先回到干净状态）
      2. 等待客户端端口就绪（默认最多 90 秒；客户端未运行时可代为启动）
      3. 端口就绪后，按客户端配置里的开关决定是否重新开启系统代理

    设计参考了 freytesla/clash-verge-proxy-autostart 的 boot 三段式思路，
    并补上它未覆盖的一环：检测残留的 HTTP_PROXY / HTTPS_PROXY 环境变量。

.PARAMETER Action
    Boot      登录时执行（默认）
    Install   把自启动项写入当前用户的「启动」文件夹
    Uninstall 移除自启动项，并结束可能在运行的 Boot 进程
    Status    查看是否已安装 + 最近日志 + 当前代理状态

.PARAMETER WaitSeconds
    等待端口就绪的最长秒数，默认 90。

.PARAMETER NoLaunch
    客户端没运行时不要代为启动。

.PARAMETER Force
    忽略客户端内部"系统代理"开关为关闭的设置，强制开启。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\boot-agent.ps1 -Action Install
    powershell -ExecutionPolicy Bypass -File .\boot-agent.ps1 -Action Status
    powershell -ExecutionPolicy Bypass -File .\boot-agent.ps1 -Action Boot -WaitSeconds 30

.NOTES
    不注册 Windows 服务、不需要管理员权限。卸载 = 删掉一个 .vbs 文件。
#>

[CmdletBinding()]
param(
    [ValidateSet('Boot', 'Install', 'Uninstall', 'Status')]
    [string]$Action = 'Boot',

    [int]$WaitSeconds = 90,

    [switch]$NoLaunch,

    [switch]$Force
)

$ErrorActionPreference = 'SilentlyContinue'

$DataDir  = Join-Path $env:LOCALAPPDATA 'ClashProxyAutostart'
$LogFile  = Join-Path $DataDir 'boot.log'
$InetKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$Startup  = [Environment]::GetFolderPath('Startup')
$VbsName  = 'ClashProxyAutostart.vbs'
$VbsPath  = Join-Path $Startup $VbsName
$SelfPath = $PSCommandPath

$DefaultBypass = 'localhost;127.*;10.*;192.168.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;<local>'

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# ---------------------------------------------------------------- 日志
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

function Invoke-LogRotation {
    try {
        if (Test-Path $LogFile) {
            $f = Get-Item $LogFile
            if ($f.Length -gt 512KB) {
                $keep = Get-Content $LogFile -Tail 200
                $keep | Set-Content $LogFile -Encoding UTF8
            }
        }
    } catch { }
}

# ---------------------------------------------------------------- 代理读写
function Get-ProxyState {
    $p = Get-ItemProperty $InetKey
    [pscustomobject]@{
        Enabled  = [int]$p.ProxyEnable
        Server   = [string]$p.ProxyServer
        Override = [string]$p.ProxyOverride
    }
}

function Invoke-WinInetRefresh {
    try {
        $sig = '[DllImport("wininet.dll", SetLastError = true)] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
        if (-not ('BootAgent.WinInet' -as [type])) {
            Add-Type -MemberDefinition $sig -Name 'WinInet' -Namespace 'BootAgent' | Out-Null
        }
        [void][BootAgent.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][BootAgent.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    } catch { }
}

function Disable-SystemProxy {
    Set-ItemProperty $InetKey -Name ProxyEnable -Value 0 -Type DWord
    Invoke-WinInetRefresh
}

function Enable-SystemProxy {
    param([string]$Server, [string]$Override)
    Set-ItemProperty $InetKey -Name ProxyServer -Value $Server -Type String
    if ($Override) { Set-ItemProperty $InetKey -Name ProxyOverride -Value $Override -Type String }
    Set-ItemProperty $InetKey -Name ProxyEnable -Value 1 -Type DWord
    Invoke-WinInetRefresh
}

# ---------------------------------------------------------------- 客户端探测
function Get-ConfigRoots {
    @(
        (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'),
        (Join-Path $env:APPDATA 'clash-verge'),
        (Join-Path $env:APPDATA 'mihomo')
    ) | Where-Object { Test-Path $_ }
}

function Read-YamlScalar {
    param([string]$Path, [string]$Key)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*:\s*(.*)$'
    foreach ($line in (Get-Content $Path)) {
        if ($line -match $pattern) {
            $v = $matches[1].Trim()
            if ($v.Length -ge 2) {
                $a = $v[0]; $b = $v[$v.Length - 1]
                if (($a -eq '"' -and $b -eq '"') -or ($a -eq "'" -and $b -eq "'")) { $v = $v.Substring(1, $v.Length - 2) }
            }
            return $v
        }
    }
    return $null
}

function Get-ProxyPort {
    # 顺序：配置文件的 mixed-port → 7897（不用残留的 ProxyServer，避免被旧端口带偏）
    foreach ($root in Get-ConfigRoots) {
        $c = Join-Path $root 'clash-verge.yaml'
        $p = Read-YamlScalar -Path $c -Key 'mixed-port'
        if ($p -match '^\d+$') { return [int]$p }
    }
    return 7897
}

function Test-PortOpen {
    param([int]$Port, [int]$TimeoutMs = 1500)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if ($task.Wait($TimeoutMs) -and (-not $task.IsFaulted) -and $client.Connected) { return $true }
    } catch { } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
    return $false
}

function Test-ClientRunning {
    [bool](Get-Process 'clash-verge', 'verge-mihomo' -ErrorAction SilentlyContinue)
}

function Find-ClientExe {
    foreach ($n in 'clash-verge', 'clash-verge-alpha') {
        $p = Get-Process $n | Select-Object -First 1
        if ($p -and $p.Path) { return $p.Path }
    }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Clash Verge\clash-verge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Clash Verge\clash-verge.exe'),
        (Join-Path $env:LOCALAPPDATA 'clash-verge\clash-verge.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Get-EnvProxyVars {
    $out = @()
    foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy') {
        $u = [Environment]::GetEnvironmentVariable($n, 'User')
        if ($u) { $out += ('{0}={1}' -f $n, $u) }
    }
    return $out
}

# ---------------------------------------------------------------- 动作
function Invoke-Boot {
    Invoke-LogRotation
    Write-Log '--- 登录自启动：开始检查 ---'

    $envVars = Get-EnvProxyVars
    if ($envVars.Count -gt 0) {
        Write-Log ('检测到代理环境变量：{0}。这些变量会让应用强制走代理，客户端未就绪时会失败。' -f ($envVars -join ', ')) 'WARN'
    }

    $port = Get-ProxyPort
    $state = Get-ProxyState
    Write-Log ('当前：ProxyEnable={0}, ProxyServer={1}, 端口={2}' -f $state.Enabled, $state.Server, $port)

    # 第 1 步：先回到干净状态（只处理"指向本机"的残留，不碰用户自定义的外部代理）
    # 关键：检查 ProxyServer 里写的那个端口，而不是配置文件里的端口
    $serverPort = $port
    if ($state.Server -match '(?:127\.0\.0\.1|localhost):(\d+)') { $serverPort = [int]$matches[1] }

    if ($state.Enabled -eq 1 -and ($state.Server -match '127\.0\.0\.1|localhost') -and $serverPort -ne $port) {
        Disable-SystemProxy
        Write-Log ('第1步：系统代理指向 {0}，与当前配置端口 {1} 不一致，已先关闭。' -f $state.Server, $port) 'ACTION'
    } elseif ($state.Enabled -eq 1 -and ($state.Server -match '127\.0\.0\.1|localhost') -and -not (Test-PortOpen -Port $serverPort -TimeoutMs 800)) {
        Disable-SystemProxy
        Write-Log ('第1步：检测到死代理（ProxyServer={0} 无响应），已关闭系统代理。' -f $state.Server) 'ACTION'
    } else {
        Write-Log '第1步：无需清理（代理未开启，或端口已就绪，或指向非本机地址）。'
    }

    # 第 2 步：等待客户端就绪
    if (-not $NoLaunch -and -not (Test-ClientRunning)) {
        $exe = Find-ClientExe
        if ($exe) {
            Write-Log ('客户端未运行，尝试启动：{0}' -f $exe)
            Start-Process -FilePath $exe | Out-Null
        } else {
            Write-Log '客户端未运行，且未找到可执行文件，跳过启动。' 'WARN'
        }
    }

    $ready = $false
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortOpen -Port $port -TimeoutMs 1200) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }

    if (-not $ready) {
        Write-Log ('第2步：等待 {0} 秒后端口 {1} 仍未就绪，保持系统代理关闭（避免死代理）。' -f $WaitSeconds, $port) 'WARN'
        return 2
    }
    Write-Log ('第2步：端口 {0} 已就绪。' -f $port)

    # 第 3 步：按客户端内部开关决定是否开启
    $toggle = $null
    foreach ($root in Get-ConfigRoots) {
        $t = Read-YamlScalar -Path (Join-Path $root 'verge.yaml') -Key 'enable_system_proxy'
        if ($null -ne $t) { $toggle = $t; break }
    }
    if (($null -ne $toggle) -and ($toggle -notmatch '^(true|1|yes|on)$') -and (-not $Force)) {
        Write-Log ('第3步：客户端内部"系统代理"开关为 {0}，尊重你的设置，不自动开启。' -f $toggle)
        return 0
    }

    $override = $state.Override
    if (-not $override) { $override = $DefaultBypass }
    Enable-SystemProxy -Server ('127.0.0.1:{0}' -f $port) -Override $override
    Write-Log ('第3步：系统代理已开启 -> 127.0.0.1:{0}' -f $port) 'ACTION'
    return 0
}

function Invoke-Install {
    Write-Host ''
    Write-Host '  安装登录自启动' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------'
    if (-not $SelfPath) {
        Write-Host '  [失败] 无法确定脚本路径，请从项目目录直接运行' -ForegroundColor Red
        return 1
    }
    if (-not $Startup -or -not (Test-Path $Startup)) {
        Write-Host '  [失败] 找不到当前用户的「启动」文件夹' -ForegroundColor Red
        return 1
    }

    $body = @(
        'Set sh = CreateObject("WScript.Shell")',
        ('sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{0}"" -Action Boot", 0, False' -f $SelfPath)
    ) -join "`r`n"

    try {
        [System.IO.File]::WriteAllText($VbsPath, $body, [System.Text.Encoding]::Default)
        Write-Host ('  [完成] 已写入：{0}' -f $VbsPath) -ForegroundColor Green
    } catch {
        Write-Host ('  [失败] 写入失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
        return 1
    }

    Write-Host ''
    Write-Host '  现在立即运行一次（可选，输入 y 立即测试）' -ForegroundColor Gray
    $a = Read-Host '  立即测试? (y/N)'
    if ($a -match '^[Yy]') {
        Write-Host ''
        Invoke-Boot | Out-Null
    }

    Write-Host ''
    Write-Host '  已启用。下次登录 Windows 时自动执行。' -ForegroundColor Green
    Write-Host ('  日志：{0}' -f $LogFile) -ForegroundColor Gray
    Write-Host '  取消：运行 autostart-uninstall.bat，或本脚本 -Action Uninstall' -ForegroundColor Gray
    return 0
}

function Invoke-Uninstall {
    Write-Host ''
    Write-Host '  卸载登录自启动' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------'

    if (Test-Path $VbsPath) {
        Remove-Item -LiteralPath $VbsPath -Force
        Write-Host '  [完成] 已删除启动项' -ForegroundColor Green
    } else {
        Write-Host '  [跳过] 启动项不存在'
    }

    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*boot-agent.ps1*' -and $_.CommandLine -like '*-Action Boot*' })
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force
        Write-Host ('  [完成] 结束运行中的守护进程 PID {0}' -f $p.ProcessId) -ForegroundColor Green
    }
    if ($procs.Count -eq 0) { Write-Host '  [跳过] 没有正在运行的守护进程' }

    Write-Host ''
    Write-Host '  已恢复为"不自动处理"，系统代理仍由客户端自己管理。' -ForegroundColor Green
    return 0
}

function Invoke-Status {
    Write-Host ''
    Write-Host '  登录自启动状态' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------'
    $installed = Test-Path $VbsPath
    if ($installed) { Write-Host '  自启动：已启用' -ForegroundColor Green }
    else            { Write-Host '  自启动：未启用（默认）' -ForegroundColor Gray }
    Write-Host ('  启动项路径：{0}' -f $VbsPath)

    $state = Get-ProxyState
    $port = Get-ProxyPort
    Write-Host ''
    Write-Host ('  系统代理：ProxyEnable={0}  ProxyServer={1}' -f $state.Enabled, $state.Server)
    Write-Host ('  端口 {0}：{1}' -f $port, $(if (Test-PortOpen -Port $port) { '可连接' } else { '无响应' }))
    Write-Host ('  客户端进程：{0}' -f $(if (Test-ClientRunning) { '运行中' } else { '未运行' }))

    $envVars = Get-EnvProxyVars
    Write-Host ''
    if ($envVars.Count -gt 0) {
        Write-Host ('  环境变量代理：{0}' -f ($envVars -join '; ')) -ForegroundColor Yellow
        Write-Host '  （建议用 -Action Fix 清理，否则客户端未启动时应用仍会失败）' -ForegroundColor Yellow
    } else {
        Write-Host '  环境变量代理：无' -ForegroundColor Green
    }

    Write-Host ''
    if (Test-Path $LogFile) {
        Write-Host '  最近日志：' -ForegroundColor Gray
        Get-Content $LogFile -Tail 8 | ForEach-Object { '    ' + $_ }
    } else {
        Write-Host '  暂无日志（尚未执行过 Boot）' -ForegroundColor Gray
    }
    return 0
}

switch ($Action) {
    'Boot'      { exit (Invoke-Boot) }
    'Install'   { exit (Invoke-Install) }
    'Uninstall' { exit (Invoke-Uninstall) }
    'Status'    { exit (Invoke-Status) }
}
