# 深入排查手册

本文件是 [README](../README.md) 的补充，面向想自己动手排查的人。

---

## 1. 先确定"是不是网络问题"

一条命令定生死：

```powershell
curl.exe -sS -o NUL -w "%{http_code}`n" --noproxy "*" https://www.bing.com
```

| 结果 | 含义 |
|---|---|
| `200` | 网络本身正常，问题一定在代理链（继续往下看） |
| 超时 / `000` | 真的是网络问题：DNS、网关、防火墙、路由 |

如果 `ping 223.5.5.5` 通、`nslookup www.baidu.com` 有结果、`Test-NetConnection www.baidu.com -Port 443` 为 True，但网页打不开 —— 基本可以锁定代理。

---

## 2. 五条代理通道逐条核对

```powershell
# ① WinINET 系统代理（浏览器 / GUI 程序读这条）
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
    Select-Object ProxyEnable, ProxyServer, AutoConfigURL

# ② 更底层的二进制标志（少数老程序读这条）
$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
     'Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections')
$b = $k.GetValue('DefaultConnectionSettings'); $k.Close()
"flags = 0x{0:X}" -f [BitConverter]::ToInt32($b, 8)
# bit 0x02 = 走代理

# ③ WinHTTP（系统服务读这条）
netsh winhttp show proxy

# ④ 环境变量（Electron / Node / Python / git / 游戏启动器读这条）
foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') {
    "{0} = {1}" -f $n, [Environment]::GetEnvironmentVariable($n,'User')
}

# ⑤ TUN 虚拟网卡（全部流量）
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'wintun|Mihomo|Clash' }
```

再加一条**端口是否真的在监听**：

```powershell
Get-NetTCPConnection -LocalPort 7897 -State Listen
```

典型故障组合：① 或 ④ 指向 `127.0.0.1:7897`，而端口查询无结果。

---

## 3. 手工修复（不想用脚本时）

```powershell
# 系统代理
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0 -Type DWord
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value ''
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name AutoConfigURL -Value ''

# WinHTTP
netsh winhttp reset proxy

# 环境变量（用户级；用之前先记下原值）
[Environment]::SetEnvironmentVariable('HTTPS_PROXY',$null,'User')
[Environment]::SetEnvironmentVariable('HTTP_PROXY',$null,'User')
[Environment]::SetEnvironmentVariable('ALL_PROXY',$null,'User')

# 让改动立即生效（否则已打开的窗口仍用旧设置）
$sig = '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);'
Add-Type -MemberDefinition $sig -Name W -Namespace N
[N.W]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[N.W]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null

ipconfig /flushdns
```

> 环境变量改完，**必须重启读它的程序**（DSH、游戏启动器、终端等），否则它们仍持有旧值。

---

## 4. 区分"代理软件问题"和"节点/订阅问题"

看到这样的日志：

```
level=error   msg="... failed to get the second response from http://www.gstatic.com/generate_204: context deadline exceeded"
level=warning msg="It is recommended to use HTTPS for provider.health-check.url ..."
```

说明**节点或订阅不通**，不是代理软件本身坏了：

- `generate_204` 超时 = 健康检查打不通，节点挂了或被阻断
- 建议在订阅里把健康检查换成 HTTPS（HTTP 探测容易被动过手脚）
- 判别：客户端里点节点测延迟，**全红 = 节点问题**；延迟正常但网页打不开 = 规则/系统代理问题

---

## 5. 游戏 / 启动器连不上

很多游戏启动器（尤其基于 Electron/CEF 的）会读 `HTTP_PROXY`：

1. 先确认环境变量是否残留（第 2 节 ④）
2. 清掉后**完全退出启动器再重开**（托盘也要退）
3. 仍不行的话，检查是否有虚拟网卡干扰：

```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status
```

常见干扰源：Radmin VPN、VirtualBox Host-Only、企业 VPN 的 VNIC。临时禁用后重试。
注意默认路由：`Get-NetRoute -DestinationPrefix '0.0.0.0/0'` 里若有虚拟网卡的默认路由且 metric 较小，会抢走流量。

---

## 6. hosts 文件里的遗留屏蔽

如果某些域名莫名解析到 `127.0.0.1` 或奇怪地址：

```powershell
Get-Content "$env:WINDIR\System32\drivers\etc\hosts" | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }
```

清理（**先备份**，需要管理员）：

```powershell
$h = "$env:WINDIR\System32\drivers\etc\hosts"
Copy-Item $h "$h.bak-$(Get-Date -f yyyyMMdd)" -Force
# 手工删掉不需要的行后：
ipconfig /flushdns
```

恢复：把 `.bak-*` 覆盖回去。

---

## 7. 排错卡片（可打印）

| 现象 | 第一反应 | 命令 | 结论 |
|---|---|---|---|
| 网页打不开，但 ping 通 | 系统代理残留 | 查 `ProxyEnable` + 端口监听 | 清代理 |
| 网页能开，应用全断 | 环境变量残留 | 查 `HTTPS_PROXY`（用户级） | 删变量 |
| 换热点也一样断 | 机器侧问题 | 同上 | 与运营商无关 |
| `curl --noproxy` 通、走代理不通 | 端口死了 | `Test-NetConnection 127.0.0.1 -Port 7897` | 重启客户端 |
| 代理开着、应用超时 | 节点/订阅 | 看客户端日志 | 换节点 |
| 游戏登录报网络错误 | 启动器读 env | 清变量后重开启动器 | 复测 |
| 域名解析到 127.0.0.1 | hosts 被改 | 查 hosts | 备份后清理 |
