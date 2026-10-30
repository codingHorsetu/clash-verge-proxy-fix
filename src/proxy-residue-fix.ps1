<#
.SYNOPSIS
    Windows 代理残留诊断与一键修复（Clash / Clash Verge Rev / mihomo 等本地 HTTP 代理通用）。

.DESCRIPTION
    解决三类问题：
      1. 系统代理（WinINET）指向一个已经没人监听的本地端口 —— 浏览器和多数桌面应用全部断网。
      2. 用户环境变量 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 指向死端口 —— 网页能开、其它应用全断。
      3. 代理进程残留 / 内核卡死 —— 界面还在，但代理实际不可用。

    完全手动触发：不注册服务、不写开机自启、不常驻后台。

.PARAMETER Action
    Check   （默认）只读诊断，不修改任何设置
    Fix     清理代理残留（环境变量 + 系统代理 + WinHTTP + DNS 缓存）
    Direct  切换到纯直连并实测连通性
    Restart 关闭残留代理并重启代理客户端
    Stop    安全退出代理客户端（先清代理，避免留下死代理）

.PARAMETER Port
    代理端口。0 表示自动从配置文件读取，读不到则用 7897。

.PARAMETER ClashExe
    代理客户端可执行文件路径，用于 Restart。留空则自动探测。

.PARAMETER BackupDir
    环境变量备份目录，默认 %LOCALAPPDATA%\ProxyResidueFix

.PARAMETER Force
    跳过交互确认（适合做成快捷方式或脚本调用）

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\proxy-residue-fix.ps1 -Action Check

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\proxy-residue-fix.ps1 -Action Fix -Force

.NOTES
    Windows PowerShell 5.1+ / PowerShell 7+。多数检查无需管理员；修改环境变量仅限当前用户。
#>

[CmdletBinding()]
param(
    [ValidateSet('Check', 'Fix', 'Direct', 'Restart', 'Stop')]
    [string]$Action = 'Check',

    [int]$Port = 0,

    [string]$ClashExe = '',

    [string]$BackupDir = (Join-Path $env:LOCALAPPDATA 'ProxyResidueFix'),

    # 连通性验证用的地址，默认取国内外都能直连的站点
    [string[]]$TestUrls = @('https://www.bing.com', 'https://www.baidu.com', 'https://www.qq.com'),

    [switch]$Force
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$script:ExitCode = 0

# =====================================================================
#  输出
# =====================================================================
function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
}
function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host ">> $Text" -ForegroundColor White
}
function Write-Ok    { param([string]$T) Write-Host "  [OK]    $T" -ForegroundColor Green }
function Write-Bad   { param([string]$T) Write-Host "  [FOUND] $T" -ForegroundColor Red }
function Write-Warn  { param([string]$T) Write-Host "  [WARN]  $T" -ForegroundColor Yellow }
function Write-Note  { param([string]$T) Write-Host "          $T" -ForegroundColor Gray }
function Write-Do    { param([string]$T) Write-Host ''; Write-Host " -> $T" -ForegroundColor White }

# =====================================================================
#  基础探测
# =====================================================================
$InetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Get-ProxyState {
    $p = Get-ItemProperty $InetKey
    [pscustomobject]@{
        Enabled  = [int]$p.ProxyEnable
        Server   = [string]$p.ProxyServer
        Override = [string]$p.ProxyOverride
        AutoCfg  = [string]$p.AutoConfigURL
    }
}

function Get-WinInetFlags {
    # Connections\DefaultConnectionSettings 里的 dwFlags，比 ProxyEnable 更底层
    $r = [pscustomobject]@{ Flags = $null; ProxyBit = $null }
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            'Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections')
        $b = $k.GetValue('DefaultConnectionSettings')
        $k.Close()
        if ($b -and $b.Length -ge 12) {
            $r.Flags    = [BitConverter]::ToInt32($b, 8)
            $r.ProxyBit = (($r.Flags -band 0x02) -ne 0)
        }
    } catch { }
    return $r
}

function Test-Listening {
    param([int]$P)
    try {
        if (Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction Stop) { return $true }
    } catch { }
    return [bool](netstat -ano | Select-String -Pattern (":{0}\s+.*LISTENING" -f $P))
}

function Get-ListenerPid {
    param([int]$P)
    try {
        $c = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($c) { return $c.OwningProcess }
    } catch { }
    return $null
}

function Get-ConfigRoots {
    $roots = @()
    $roots += (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev')
    $roots += (Join-Path $env:APPDATA 'clash-verge')
    $roots += (Join-Path $env:APPDATA 'mihomo')
    return ($roots | Where-Object { Test-Path $_ })
}

function Get-ConfiguredPort {
    if ($Port -gt 0) { return $Port }
    foreach ($root in Get-ConfigRoots) {
        foreach ($name in 'clash-verge.yaml', 'config.yaml') {
            $f = Join-Path $root $name
            if (Test-Path $f) {
                $m = Select-String -Path $f -Pattern '^mixed-port:\s*(\d+)' | Select-Object -First 1
                if ($m) { return [int]$m.Matches[0].Groups[1].Value }
            }
        }
    }
    return 7897
}

function Get-Mode {
    foreach ($root in Get-ConfigRoots) {
        $f = Join-Path $root 'clash-verge.yaml'
        if (Test-Path $f) {
            $m = Select-String -Path $f -Pattern '^mode:\s*(\S+)' | Select-Object -First 1
            if ($m) { return $m.Matches[0].Groups[1].Value }
        }
    }
    return $null
}

# ---------------------------------------------------------------- 环境变量
function Get-EnvProxyVars {
    $out = @()
    foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy') {
        $u = [Environment]::GetEnvironmentVariable($n, 'User')
        $m = [Environment]::GetEnvironmentVariable($n, 'Machine')
        if ($u -or $m) {
            $out += [pscustomobject]@{ Name = $n; User = $u; Machine = $m }
        }
    }
    return $out
}

function Remove-EnvProxyVars {
    $vars = Get-EnvProxyVars
    if ($vars.Count -eq 0) { return $null }

    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $backup = Join-Path $BackupDir ('proxy-env-backup-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $lines = @('# 代理环境变量备份 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    foreach ($v in $vars) {
        if ($v.User)    { $lines += ('{0}={1}' -f $v.Name, $v.User) }
        if ($v.Machine) { $lines += ('# system-level (needs admin): {0}={1}' -f $v.Name, $v.Machine) }
    }
    $lines | Set-Content -Path $backup -Encoding UTF8

    $removed = @()
    foreach ($v in $vars) {
        if ($v.User) {
            [Environment]::SetEnvironmentVariable($v.Name, $null, 'User')
            $removed += $v.Name
        }
    }

    # 广播 WM_SETTINGCHANGE，让新启动的进程立刻拿到干净环境
    try {
        $sig = @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        if (-not ('ProxyResidue.Native' -as [type])) {
            Add-Type -MemberDefinition $sig -Name 'Native' -Namespace 'ProxyResidue' | Out-Null
        }
        $res = [UIntPtr]::Zero
        [void][ProxyResidue.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 3000, [ref]$res)
    } catch { }

    return [pscustomobject]@{ Removed = $removed; Backup = $backup }
}

# ---------------------------------------------------------------- 系统代理
function Set-ProxyOff {
    Set-ItemProperty $InetKey -Name ProxyEnable -Value 0 -Type DWord
    Set-ItemProperty $InetKey -Name ProxyServer -Value ''
    Set-ItemProperty $InetKey -Name AutoConfigURL -Value '' -ErrorAction SilentlyContinue
    try {
        $sig = @'
[DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
        if (-not ('ProxyResidue.WinInet' -as [type])) {
            Add-Type -MemberDefinition $sig -Name 'WinInet' -Namespace 'ProxyResidue' | Out-Null
        }
        [void][ProxyResidue.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][ProxyResidue.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    } catch { }
    netsh winhttp reset proxy | Out-Null
    ipconfig /flushdns | Out-Null
}

function Set-ProxyOn {
    param([int]$P)
    Set-ItemProperty $InetKey -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty $InetKey -Name ProxyServer -Value ("127.0.0.1:{0}" -f $P)
    try {
        $sig = @'
[DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
        if (-not ('ProxyResidue.WinInet' -as [type])) {
            Add-Type -MemberDefinition $sig -Name 'WinInet' -Namespace 'ProxyResidue' | Out-Null
        }
        [void][ProxyResidue.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][ProxyResidue.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    } catch { }
}

# ---------------------------------------------------------------- 客户端
function Find-ClientExe {
    if ($ClashExe -and (Test-Path $ClashExe)) { return $ClashExe }
    foreach ($n in 'clash-verge', 'clash-verge-alpha') {
        $p = Get-Process $n | Select-Object -First 1
        if ($p -and $p.Path) { return $p.Path }
    }
    $candidates = @(
        'C:\Program Files\Clash Verge\clash-verge.exe',
        'C:\Program Files (x86)\Clash Verge\clash-verge.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Clash Verge\clash-verge.exe'),
        'C:\Program Files\Clash Verge Rev\clash-verge.exe'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Get-LastExitInfo {
    foreach ($root in Get-ConfigRoots) {
        $logDir = Join-Path $root 'logs'
        if (-not (Test-Path $logDir)) { continue }
        foreach ($f in (Get-ChildItem $logDir -Filter '*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
            if ($f.Length -eq 0) { continue }
            $tail = (Get-Content $f.FullName -Tail 30 -Encoding UTF8) -join "`n"
            if ($tail -match '系统代理已重置|proxy.*reset|cleanup') {
                $code = '0'
                if ($tail -match '退出代码[：:\s]*(\d+)') { $code = $matches[1] }
                return [pscustomobject]@{ Clean = $true; File = $f.Name; Time = $f.LastWriteTime; ExitCode = $code }
            }
        }
    }
    return $null
}

function Test-Url {
    param([string]$Url, [int]$TimeoutSec = 8)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return [pscustomobject]@{ Url = $Url; Code = $r.StatusCode; Ms = $sw.ElapsedMilliseconds; Ok = $true }
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code) { return [pscustomobject]@{ Url = $Url; Code = $code; Ms = $sw.ElapsedMilliseconds; Ok = $true } }
        return [pscustomobject]@{ Url = $Url; Code = 0; Ms = $sw.ElapsedMilliseconds; Ok = $false; Error = $_.Exception.Message }
    }
}

function Confirm-Step {
    param([string]$Message)
    if ($Force) { return $true }
    $a = Read-Host "  $Message (y/N)"
    return ($a -match '^[Yy]')
}

# =====================================================================
#  1. 采集
# =====================================================================
$ProxyPort  = Get-ConfiguredPort
$Mode       = Get-Mode
$UiProc     = Get-Process 'clash-verge'         -ErrorAction SilentlyContinue
$CoreProc   = Get-Process 'verge-mihomo'        -ErrorAction SilentlyContinue
$SvcProc    = Get-Process 'clash-verge-service' -ErrorAction SilentlyContinue
$Listening  = Test-Listening -P $ProxyPort
$ListenerPid = Get-ListenerPid -P $ProxyPort
$Proxy      = Get-ProxyState
$Flags      = Get-WinInetFlags
$EnvVars    = @(Get-EnvProxyVars)
$EnvFound   = ($EnvVars.Count -gt 0)
$PointsHere = ($Proxy.Server -match ('127\.0\.0\.1:{0}\b' -f $ProxyPort))

Write-Head ('Proxy residue check - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

Write-Section 'Process'
if ($UiProc)   { Write-Ok  ('Clash Verge UI running (PID {0})' -f ($UiProc | Select-Object -First 1).Id) }
else           { Write-Note 'Clash Verge UI not running (fine if you closed it)' }
if ($CoreProc) { Write-Ok  ('proxy core verge-mihomo running (PID {0})' -f ($CoreProc | Select-Object -First 1).Id) }
elseif ($UiProc) { Write-Bad 'UI is running but the proxy core is NOT - client is hung' }
else           { Write-Note 'proxy core not running (proxy client closed)' }
if ($SvcProc)  { Write-Ok  ('clash-verge-service running (PID {0})' -f ($SvcProc | Select-Object -First 1).Id) }
else           { Write-Note 'clash-verge-service not running (only needed for admin mode)' }

Write-Section ('Port {0}' -f $ProxyPort)
if ($Listening) {
    Write-Ok ('listening, owned by PID {0}' -f $ListenerPid)
    if ($ListenerPid -and $CoreProc) {
        $ids = @($CoreProc | ForEach-Object { $_.Id })
        if ($ids -notcontains $ListenerPid) {
            Write-Warn ('listener is not verge-mihomo (PID {0}) - another program may own this port' -f $ListenerPid)
        }
    }
} else {
    if ($CoreProc -or $UiProc) { Write-Bad ('port {0} is NOT listening - proxy is dead while the app still runs' -f $ProxyPort) }
    else                       { Write-Note ('port {0} not listening (expected while the client is closed)' -f $ProxyPort) }
}

Write-Section 'System proxy (WinINET)'
if ($Proxy.Enabled -eq 1) {
    Write-Note ('ProxyEnable = 1 -> {0}' -f $Proxy.Server)
    if ($PointsHere) { Write-Ok ('points to the configured port {0}' -f $ProxyPort) }
    else             { Write-Warn ('points to a different address than port {0}' -f $ProxyPort) }
} else {
    Write-Note 'ProxyEnable = 0 (applications connect directly)'
}
if ($Proxy.AutoCfg) { Write-Warn ('PAC is configured: {0}' -f $Proxy.AutoCfg) }
if ($Flags.Flags -ne $null) {
    Write-Note ('WinINET blob flags=0x{0:X}, proxy bit={1}' -f $Flags.Flags, $Flags.ProxyBit)
    if ($Flags.ProxyBit -and $Proxy.Enabled -eq 0) {
        Write-Warn 'registry switch is off but the blob still has the proxy bit set - some legacy apps may still use it'
    }
}

Write-Section 'Proxy environment variables'
if (-not $EnvFound) {
    Write-Ok 'no HTTP_PROXY / HTTPS_PROXY / ALL_PROXY in user or machine scope'
} else {
    foreach ($v in $EnvVars) {
        if ($v.User)    { Write-Bad ('user    {0} = {1}' -f $v.Name, $v.User) }
        if ($v.Machine) { Write-Bad ('machine {0} = {1} (needs admin to change)' -f $v.Name, $v.Machine) }
    }
    Write-Note 'Electron / Node / Python / git / curl / many game launchers read these.'
    Write-Note 'Browsers do NOT - that is why "web pages work but every app fails".'
}

Write-Section 'DNS and routing leftovers'
$fake = @(Get-DnsClientCache | Where-Object { $_.Data -like '198.18.*' })
if ($fake.Count -gt 0) { Write-Warn ('{0} fake-ip entries in the DNS cache (198.18.x.x)' -f $fake.Count) }
else                   { Write-Ok 'no fake-ip entries in the DNS cache' }
$tun = @(Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'wintun|Mihomo|Clash' -and $_.Status -eq 'Up' })
if ($tun.Count -gt 0) { Write-Note ('active TUN adapter: {0}' -f (($tun | ForEach-Object { $_.Name }) -join ', ')) }
else                  { Write-Ok 'no active TUN adapter' }

Write-Section 'Client mode'
if ($Mode) {
    if ($Mode -eq 'global')     { Write-Warn 'mode = global: every connection goes abroad, including domestic services' }
    elseif ($Mode -eq 'rule')   { Write-Ok 'mode = rule: domestic direct, foreign via proxy' }
    elseif ($Mode -eq 'direct') { Write-Note 'mode = direct: the proxy forwards nothing' }
    else                        { Write-Note ('mode = {0}' -f $Mode) }
} else {
    Write-Note 'mode not found in config'
}

Write-Section 'History'
$lastExit = Get-LastExitInfo
if ($lastExit) { Write-Ok ('last exit looks clean ({0}, {1}, exit code {2})' -f $lastExit.Time.ToString('MM-dd HH:mm'), $lastExit.File, $lastExit.ExitCode) }
else           { Write-Warn 'no clean-shutdown record found in the logs (may have been force-killed)' }
$crashes = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'CrashDumps') -Filter '*clash*' |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) }).Count
if ($crashes -gt 0) { Write-Warn ('{0} crash dump(s) in the last 7 days' -f $crashes) }
else                { Write-Ok 'no crash dumps in the last 7 days' }

# =====================================================================
#  2. 判定
# =====================================================================
if ($CoreProc -and $Listening) {
    if ($Proxy.Enabled -eq 1 -and $PointsHere) { $State = 'HEALTHY';     $Diag = 'client and system proxy agree - everything is consistent.' }
    elseif ($Proxy.Enabled -eq 1)              { $State = 'WRONG_PORT';  $Diag = ('system proxy points to {0}, but the proxy listens on {1}.' -f $Proxy.Server, $ProxyPort) }
    else                                       { $State = 'NOT_CAPTURED'; $Diag = 'client is running but system proxy is off - proxy-aware apps bypass it.' }
} elseif ($Proxy.Enabled -eq 1 -and $Proxy.Server -match '127\.0\.0\.1|localhost') {
    $State = 'STALE';  $Diag = ('system proxy still points to {0} but nothing listens there - every proxy-aware app is offline.' -f $Proxy.Server)
} elseif ($UiProc -or $CoreProc) {
    $State = 'ZOMBIE'; $Diag = 'proxy processes remain but the core is not listening - hung state.'
} else {
    $State = 'DIRECT'; $Diag = 'proxy client not running and system proxy is off - pure direct connection.'
}

Write-Head 'Diagnosis'
switch ($State) {
    'HEALTHY'     { Write-Ok   $Diag }
    'DIRECT'      { Write-Ok   $Diag }
    'STALE'       { Write-Bad  $Diag; Write-Note 'Fix: turn the system proxy off (Action Fix / Direct).' }
    'ZOMBIE'      { Write-Bad  $Diag; Write-Note 'Fix: kill the leftovers and restart the client.' }
    'WRONG_PORT'  { Write-Warn $Diag; Write-Note 'Fix: reset the system proxy, or restart the client so it re-applies.' }
    'NOT_CAPTURED'{ Write-Warn $Diag }
    default       { Write-Warn $Diag }
}
if ($EnvFound) {
    Write-Bad 'proxy environment variables are set - they break apps even when the system proxy is correct.'
    Write-Note 'Symptom: web pages load, every other app fails, and switching networks does not help.'
    Write-Note 'Fix: run with -Action Fix (backs up, then removes them).'
}
if ($State -ne 'HEALTHY' -and $State -ne 'DIRECT' -or $EnvFound) { $script:ExitCode = 1 }

# =====================================================================
#  3. 动作
# =====================================================================
function Invoke-FixEnv {
    if (-not $EnvFound) { return }
    Write-Do 'Proxy environment variables'
    if (-not (Confirm-Step 'Back up and remove these environment variables?')) { Write-Note 'skipped'; return }
    $r = Remove-EnvProxyVars
    if ($r -and $r.Removed.Count -gt 0) {
        Write-Ok ('removed: {0}' -f ($r.Removed -join ', '))
        Write-Note ('backup: {0}' -f $r.Backup)
        Write-Note 'already-running apps must be restarted to pick this up.'
    } else {
        Write-Warn 'nothing removed (group policy or machine-level variable?)'
    }
}

function Invoke-FixProxy {
    Write-Do 'System proxy'
    Set-ProxyOff
    Start-Sleep -Milliseconds 400
    if ((Get-ProxyState).Enabled -eq 0) { Write-Ok 'system proxy disabled, WinHTTP reset, DNS cache flushed' }
    else                                { Write-Bad 'could not disable system proxy (something keeps re-enabling it)' }
}

switch ($Action) {

    'Check' {
        Write-Head 'Result'
        Write-Note 'read-only mode - nothing was changed.'
        Write-Note 'run with -Action Fix to repair, or double-click quick-fix.bat'
        exit $script:ExitCode
    }

    'Fix' {
        Write-Head 'Applying fix'
        Invoke-FixEnv
        if ((Get-ProxyState).Enabled -eq 1 -or $State -eq 'ZOMBIE') {
            if (Confirm-Step 'Disable the system proxy and reset WinHTTP?') {
                Invoke-FixProxy
            } else { Write-Note 'skipped' }
        } elseif ($State -eq 'DIRECT' -or $State -eq 'HEALTHY') {
            Write-Note 'system proxy does not need changes.'
        }

        Write-Do 'Verify'
        foreach ($u in $TestUrls) {
            $t = Test-Url $u
            if ($t.Ok) { Write-Ok ('{0,-26} HTTP {1}  ({2} ms)' -f $t.Url, $t.Code, $t.Ms) }
            else       { Write-Bad ('{0,-26} failed: {1}' -f $t.Url, $t.Error) }
        }
        break
    }

    'Direct' {
        Write-Head 'Switch to direct'
        if (-not (Confirm-Step 'Turn off the system proxy and cut the proxy env vars?')) { Write-Note 'cancelled'; break }
        Invoke-FixEnv
        Invoke-FixProxy

        Write-Do 'Verify'
        $bad = 0
        foreach ($u in $TestUrls) {
            $t = Test-Url $u
            if ($t.Ok) { Write-Ok ('{0,-26} HTTP {1}  ({2} ms)' -f $t.Url, $t.Code, $t.Ms) }
            else       { Write-Bad ('{0,-26} failed: {1}' -f $t.Url, $t.Error); $bad++ }
        }
        if ($bad -eq 0) { Write-Ok 'direct connection works - no proxy client needed' }
        else            { Write-Warn 'some targets failed - look for DNS / firewall / routing issues' }
        break
    }

    'Restart' {
        Write-Head 'Restart proxy client'
        if (-not (Confirm-Step 'Kill the client and start it again?')) { Write-Note 'cancelled'; break }
        Set-ProxyOff
        foreach ($n in 'clash-verge', 'verge-mihomo') {
            $p = Get-Process $n
            if ($p) { $p | ForEach-Object { Stop-Process -Id $_.Id -Force }; Write-Note ("stopped {0}" -f $n) }
        }
        Start-Sleep -Seconds 2

        $exe = Find-ClientExe
        if (-not $exe) { Write-Bad 'client executable not found - start it manually'; break }
        Start-Process -FilePath $exe | Out-Null
        Write-Note ("started {0}" -f $exe)

        $ready = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 1
            if (Test-Listening -P $ProxyPort) { $ready = $true; break }
        }
        if ($ready) {
            Write-Ok ('port {0} is listening again' -f $ProxyPort)
            Start-Sleep -Seconds 2
            if ((Get-ProxyState).Enabled -eq 1) { Write-Ok 'client took over the system proxy' }
            else { Set-ProxyOn -Port $ProxyPort; Write-Ok ('system proxy set to 127.0.0.1:{0}' -f $ProxyPort) }
        } else {
            Write-Bad 'port did not come up - check the client window / logs'
        }
        break
    }

    'Stop' {
        Write-Head 'Stop proxy client safely'
        Write-Note 'the tray menu exit is preferred; this path clears the system proxy first.'
        if (-not (Confirm-Step 'Stop the client now?')) { Write-Note 'cancelled'; break }
        Set-ProxyOff
        Write-Ok 'system proxy cleared first'
        foreach ($n in 'clash-verge', 'verge-mihomo') {
            $p = Get-Process $n
            if ($p) { $p | ForEach-Object { Stop-Process -Id $_.Id -Force }; Write-Note ("stopped {0}" -f $n) }
        }
        Start-Sleep -Seconds 1
        if (-not (Get-Process 'clash-verge') -and -not (Get-Process 'verge-mihomo')) {
            Write-Ok 'client stopped, machine is on direct connection'
        } else { Write-Warn 'some processes survived, retry in a moment' }
        break
    }
}

Write-Host ''
exit $script:ExitCode
