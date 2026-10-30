# Clash Verge 代理残留修复工具

> 关掉 Clash Verge 后**网页打不开 / 应用全部连不上**？这个工具就是修这个的。
>
> 一个**只在你手动双击时才运行**的 PowerShell 小工具：诊断并清理 Windows 上残留的代理设置。不注册服务、不开机自启、不常驻后台，跑完即退。
>
> 专为 Clash Verge / Clash Verge Rev 设计，同样适用于 Clash / mihomo / v2rayN 等任何在 `127.0.0.1:端口` 上提供 HTTP 代理的客户端。

---

## 症状对照：你中的是哪一种

| 现象 | 很可能的原因 |
|---|---|
| 网页打不开，微信/QQ 也连不上，但 `ping` 通、DNS 正常 | **系统代理残留**（端口死了，开关还开着） |
| **网页能开**，其它应用全连不上，**换手机热点也一样** | **环境变量代理残留**（`HTTP_PROXY` 写死在用户环境） |
| 应用能连但登录失败 / 游戏报网络错误 | 代理走了境外节点，或启动器读到了死代理 |
| 客户端界面还在，但代理不工作 | 内核进程挂了（僵尸进程） |

最后一行最重要：**换网络也不行，就说明问题在机器上，与运营商无关。**

---

## 30 秒速判（不想跑脚本时）

```powershell
# ① 系统代理开关
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select ProxyEnable,ProxyServer

# ② 代理端口是否真的有人在听
Test-NetConnection 127.0.0.1 -Port 7897 -InformationLevel Quiet

# ③ 环境变量里有没有残留（最容易被忽略）
[Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')

# ④ 绕过代理直连，判断"到底是不是网络问题"
curl.exe -sS -o NUL -w "%{http_code}`n" --noproxy "*" https://www.bing.com
```

| ① 系统代理 | ② 端口 | ③ 环境变量 | 结论 |
|---|---|---|---|
| 1 | True | 任意 | 正常在用代理 |
| 1 | **False** | 任意 | **系统代理残留** → 运行本工具修复 |
| 0 | False | **有值** | **环境变量残留** → 运行本工具修复 |
| 0 | False | 空 | ④ 也失败 → 真的是网络/DNS/防火墙问题 |
| 0 | True | 任意 | 客户端在跑，但没接管系统代理 |

④ 返回 `200` 却打不开网页 = **网络没问题，问题在代理链**。

---

## 使用

### 方式一：双击（推荐）

```
quick-fix.bat      # 一键：先诊断，再修复，最后停住显示结果
menu.bat           # 菜单：可选择单独诊断 / 修复 / 切直连 / 重启 / 退出客户端
```

### 方式二：命令行

```powershell
# 只诊断，不改任何设置
powershell -ExecutionPolicy Bypass -File .\src\proxy-residue-fix.ps1 -Action Check

# 修复（自动备份环境变量）
powershell -ExecutionPolicy Bypass -File .\src\proxy-residue-fix.ps1 -Action Fix

# 切到纯直连并实测连通性
powershell -ExecutionPolicy Bypass -File .\src\proxy-residue-fix.ps1 -Action Direct

# 重启客户端（自动探测安装路径）
powershell -ExecutionPolicy Bypass -File .\src\proxy-residue-fix.ps1 -Action Restart

# 安全退出客户端（先清系统代理，避免留下死代理）
powershell -ExecutionPolicy Bypass -File .\src\proxy-residue-fix.ps1 -Action Stop
```

`Fix` 与 `Direct` 会交互确认；加 `-Force` 可跳过（`quick-fix.bat` 就是这么调的）。

### 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-Action` | `Check` | `Check` / `Fix` / `Direct` / `Restart` / `Stop` |
| `-Port` | 自动 | 从配置文件读 `mixed-port`，读不到用 `7897` |
| `-ClashExe` | 自动 | `Restart` 用；自动探测常见安装路径与运行中进程 |
| `-BackupDir` | `%LOCALAPPDATA%\ProxyResidueFix` | 环境变量备份目录 |
| `-TestUrls` | bing / baidu / qq | 连通性验证目标 |
| `-Force` | 关 | 跳过交互确认 |

---

## 它到底改了什么

修复（`Fix` / `Direct`）只做这几件事，全部可逆：

1. **备份并删除**用户级 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`（备份文件名带时间戳）
2. 关闭 WinINET 系统代理（`ProxyEnable=0`，清空 `ProxyServer`）
3. `netsh winhttp reset proxy`（服务类程序走这条通道）
4. `ipconfig /flushdns`

**不会**改：网络适配器、DNS 服务器、路由表、hosts、防火墙规则、任何第三方软件。
**不需要**管理员权限（只有系统级环境变量才需要，脚本会提示但不硬改）。

恢复代理：重新启动代理客户端即可，它启动时会自动把系统代理设回去。

---

## 为什么会出现这种故障

Windows 上"代理"并不是一个开关，而是**五条互不相干的通道**：

| 通道 | 谁在读 | 出问题时的表现 |
|---|---|---|
| WinINET 系统代理（注册表） | 浏览器、微信、Office、多数 GUI | 网页也打不开 |
| WinHTTP 代理（`netsh winhttp`） | 系统服务、部分更新组件 | 更新/登录类功能失败 |
| 环境变量 `*_PROXY` | Electron、Node、Python、git、curl、**多数游戏启动器** | **网页正常，其它应用全断** |
| PAC 自动配置脚本 | 少数老程序 | 视脚本内容而定 |
| TUN 虚拟网卡 | 全部流量 | 网卡消失后路由中断 |

代理客户端退出时通常只清理"自己设过的那一条"。如果它被强行结束（任务管理器结束进程、崩溃、关机时没等清理完成），那条也不会被清理 —— 于是：

- 端口已经没人监听
- 系统代理/环境变量还指向那个端口
- 所有读它的程序连接被立即拒绝

而 **Windows 自带的网络诊断只测 IP、网关、DNS，不测代理链**，所以它永远显示"一切正常"。

### 浏览器为什么是例外

浏览器读的是 WinINET 系统代理，**不读环境变量**。所以当残留发生在环境变量上时：

- 浏览器 → 直连 → 网页正常
- Electron / Node / 游戏启动器 → 读到死代理 → 全部失败

这就是「网页能开、应用全断」的全部原因。

---

## 防复发

1. 退出代理客户端时用**托盘菜单 → 退出**，不要用任务管理器结束进程。
2. 客户端里若有「系统代理守卫 / Proxy Guard」，打开它（进程异常退出时自动关掉系统代理）。
3. **不要给用户级环境变量设全局代理**。需要时用 `tools\with-proxy.bat <命令>`，只影响那一个窗口。
4. 模式用**规则（rule）**，不要长期停在全局（global）—— 全局会让国内服务也绕道境外节点。
5. 改完代理设置后，**重启相关程序**；已经运行的进程不会自动更新环境变量。

---

## 常见问题

**Q：会不会把网络设置改坏？**
不会。只动 4 项代理相关设置，且全部可逆：重开代理客户端即可恢复。

**Q：需要管理员权限吗？**
不需要。脚本对系统级环境变量只做提示，不会强改。

**Q：支持哪些客户端？**
任何在本地端口提供 HTTP 代理的客户端。端口自动从 Clash Verge 配置读取，读不到默认 `7897`；可用 `-Port` 指定。

**Q：诊断显示"环境变量残留"，但我没手动设过？**
多半是某个工具（CLI 代理配置、AI 助手的"帮你配好代理"、安装脚本）写进去的。这正是本工具最常见的使用场景。

**Q：修完还是打不开网页？**
先看诊断里 `curl --noproxy` 那条：如果它也失败，问题不在代理，去查 DNS / 防火墙 / 路由。详见 [docs/diagnosis.md](docs/diagnosis.md)。

---

## 目录结构

```
quick-fix.bat                 一键修复（先诊断再修复）
menu.bat                      菜单
src/proxy-residue-fix.ps1     主脚本
tools/with-proxy.bat          只给单个命令加代理
docs/diagnosis.md             深入排查手册（手工命令、hosts、节点问题）
```

---

## 许可

[MIT](LICENSE)。欢迎提 issue / PR。
