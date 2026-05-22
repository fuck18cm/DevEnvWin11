# 设计稿：Win11 原生 clautel + 保活，Ubuntu 拆除 WSL 保活

日期：2026-05-22（2026-05-22 修订：latest / 静默 / 排他）  
状态：已批准；实施计划见 [`docs/superpowers/plans/2026-05-22-clautel-win11-native.md`](../plans/2026-05-22-clautel-win11-native.md)  
关联 spec（Ubuntu 拆除）：`../DevEnvUbuntu/docs/superpowers/specs/2026-05-22-remove-clautel-design.md`（路径相对于 `D:\dev_env` 兄弟仓库）

## 1. 目标

| 仓库 | 变更 |
|------|------|
| **DevEnvWin11** | 菜单新增 `9. clautel`：`npm install -g clautel` + 注册 Windows 任务计划 `DevEnvWin11-Clautel-Keepalive`（`AtStartup` S4U + 5 分钟心跳），在**原生 Windows** 上保活 daemon |
| **DevEnvUbuntu** | 按 `2026-05-22-remove-clautel-design.md` 拆除：删除 `11-clautel.sh`、`12-keepalive.sh`、`windows/` 保活目录及相关文档/校验 |

**不在范围内：** `clautel setup` / license 自动化；在 Win11 安装器内安装 Claude Code（用户须已具备 `claude` 命令）。

## 2. 背景与动机

- clautel 原先装在 **DevEnvUbuntu（WSL）**，依赖 systemd user service + Windows **VM Holder**（`wsl.exe sleep infinity` + 任务计划）维持 WSL VM 与 daemon 在线。维护成本高，且 license-proxy 不稳定。
- clautel 的 `install-service` **仅支持 macOS launchd**（README）；Linux 为 systemd，**Windows 无官方服务集成**，需任务计划实现 `clautel start` / 探活。
- 用户决策（brainstorming 2026-05-22）：
  - 两仓库同步改（B）
  - 只装工具 + 任务，不跑 `clautel setup`（A）
  - 保活：`AtStartup` + S4U，开机即启（B）
  - 硬依赖 `node`/`npm` 与 `claude`（A）
  - 实现形态：**方案 1** —— Win11 单文件 `dev_env.bat` 扩展 + Ubuntu 按既有拆除 spec 执行

## 3. 已确认的设计决策

| 决策点 | 选择 |
|--------|------|
| Win11 结构 | `$TaskClautel` 脚本块 + 运行时生成 watch 脚本到 `%LOCALAPPDATA%\DevEnvWin11\` |
| `clautel setup` | 不纳入安装器；未配置时 watch 脚本 `[SKIP]` 退出 0 |
| 任务触发 | `AtStartup`（Principal：安装时的交互用户 + `LogonType S4U`）+ 每 5 分钟重复 |
| 前置依赖 | 缺 `node`/`npm` 或 `claude` → `throw`，提示先装菜单 `2` 与官方 Claude Code |
| `all` 菜单 | **默认不包含** `9`；需要 clautel 时选 `9` 或 `all,9` |
| 旧 WSL 保活 | Win11 注册新任务时**自动卸载** `DevEnvUbuntu-WSL-VMHolder`、`DevEnvUbuntu-WSL-Keepalive`（若存在），并打印提示 |
| clautel 版本 | **始终安装 npm latest**：`npm install -g clautel@latest`（不写入 `$v`，每次选菜单 9 都执行升级） |
| 保活执行方式 | **全程后台静默**：任务 Action 经 `wscript.exe` + launcher VBS（`vbHide=0`）拉起 watch；**禁止**任务计划直接 `powershell.exe` 作 Execute（易闪黑框） |
| 排他性 | **双层**：任务计划 `MultipleInstances IgnoreNew` + watch 脚本命名 Mutex；daemon 已 running 则不再 `clautel start` |
| Ubuntu 拆除 | 不重复设计；严格执行 `remove-clautel-design.md`，README 保留手动迁移清单 |

## 4. DevEnvWin11 详细设计

### 4.1 版本与路径

- **不**在 `$v` / `$paths` / `$urls` 增加 clautel 项（与「始终 latest」一致）。
- 幂等：每次菜单 9 都跑 `npm install -g clautel@latest`；成功后打印 `clautel --version` 供日志确认当前版本。

### 4.2 `$TaskClautel` 流程

```
1. Write-Host ">> clautel"
2. 硬依赖：
   - Test-CommandAvailable node, npm → 否则 throw "Node required. Run menu 2 first."
   - Test-CommandAvailable claude → 否则 throw "Claude Code CLI required. Install from https://code.claude.com/docs/en/setup"
3. 安装/升级（每次执行，不跳过）：
   - npm install -g clautel@latest
4. 迁移：Unregister-ScheduledTask DevEnvUbuntu-WSL-*（见 §4.4）
5. 写入运行时文件 + 注册保活：Ensure-ClautelKeepaliveTask（见 §4.3）
6. 完成提示：若未配置，打印 "Run: clautel setup && clautel activate <key>"
```

**说明：** 即使 `clautel` 已在 PATH，仍执行 `npm install -g clautel@latest` 以拉到最新版；任务计划与 VBS/PS1 每次重写，保证静默启动逻辑可更新。

### 4.3 任务计划 `DevEnvWin11-Clautel-Keepalive`（静默 + 排他）

**函数：** `Ensure-ClautelKeepaliveTask`（放在 helper 区，与 `Ensure-AndroidCmdlineTools` 同级）

**运行时目录：** `%LOCALAPPDATA%\DevEnvWin11\`

| 文件 | 作用 |
|------|------|
| `clautel-watch.ps1` | 探活 / 启动逻辑（仅由 VBS 以隐藏方式调用） |
| `clautel-watch-launch.vbs` | 任务计划唯一 Action 入口；`WshShell.Run(..., 0, False)`，`0` = `vbHide` |
| `clautel-watch.log` | 追加日志 |

| 属性 | 值 |
|------|-----|
| TaskName | `DevEnvWin11-Clautel-Keepalive` |
| 触发器 1 | `AtStartup` |
| 触发器 2 | 每 5 分钟，无限重复（`RepetitionInterval PT5M`；**不**设 `RepetitionDuration`，因 `MaxValue` 在 Win11 会报 XML 范围错误） |
| Principal | 当前安装用户（`$env:USERNAME` 对应 SID），`LogonType S4U`，`RunLevel Limited` |
| Settings | `Hidden` = true，`AllowStartIfOnBatteries`，`DontStopIfGoingOnBatteries`，**`MultipleInstances IgnoreNew`**，`RestartCount 999`，`RestartInterval PT1M` |
| Action | **`%SystemRoot%\System32\wscript.exe`**，参数：`//B //Nologo "%LOCALAPPDATA%\DevEnvWin11\clautel-watch-launch.vbs"` |

**为何用 VBS 包一层：** 任务计划直接执行 `powershell.exe` 时，在部分 Windows 版本上仍会短暂出现控制台窗口。DevEnvUbuntu 的 VM Holder 已验证：`wscript.exe` + `WshShell.Run(cmd, 0, False)` 可做到无黑框。**禁止**使用 `WshShell.Exec`（会强制 `SW_SHOWNORMAL` 闪窗）。

**`clautel-watch-launch.vbs`（安装时生成，ASCII）：**

```vbscript
' DevEnvWin11: hidden launcher for clautel-watch.ps1
ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""..." & watchPs1 & """"
CreateObject("WScript.Shell").Run ps, 0, False
```

**Watch 脚本 `clautel-watch.ps1`：**

```powershell
# --- (1) 排他：本脚本同时只跑一个实例 ---
$mutexName = "Global\DevEnvWin11-Clautel-Watch"
$created = $false
$mtx = New-Object Threading.Mutex($false, $mutexName, [ref]$created)
if (-not $created) { exit 0 }   # 另一实例正在跑，直接退出
try {
  # --- (2) 日志 ---
  # Append-Log；>512KB 截断留尾 256KB

  # --- (3) 未配置则 SKIP ---
  if (-not (Test-Path "$env:USERPROFILE\.clautel\config.json")) {
    Append-Log "[SKIP] clautel not configured; run clautel setup"
    exit 0
  }

  # --- (4) daemon 排他：已 running 不再 start ---
  $st = & clautel status 2>&1 | Out-String
  if ($st -match 'running') { Append-Log "[OK] already running"; exit 0 }

  # --- (5) 静默启动 daemon（避免 clautel start 子进程弹窗）---
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command clautel).Source
  $psi.Arguments = "start"
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  # 烘焙 PATH：与任务 Environment 一致（NVM、.local\bin、npm global）
  $psi.Environment["PATH"] = <resolved-path>
  [Diagnostics.Process]::Start($psi) | Out-Null
  Append-Log "[START] clautel start (no window)"
} finally {
  $mtx.ReleaseMutex()
}
```

**排他性分层：**

| 层级 | 机制 | 效果 |
|------|------|------|
| 任务计划 | `MultipleInstances IgnoreNew` + `Hidden` | 上一轮 watch 未结束时，新触发不叠实例；任务本身不弹 UI |
| Watch 脚本 | `Global\DevEnvWin11-Clautel-Watch` Mutex | 5 分钟心跳与 AtStartup 重叠时，只有一个 PS 实例执行探活 |
| clautel daemon | `clautel status` → `running` 则跳过 `start` | 不重复拉起 daemon |

**PATH 烘焙（任务 Environment + ProcessStartInfo）：** 任务 `Environment` 与 watch 内 `ProcessStartInfo` 使用同一套解析逻辑：

- `%NVM_HOME%`、`%NVM_SYMLINK%`（与 `$TaskNode` 写入的 Machine 变量一致）
- `%USERPROFILE%\.local\bin`（Claude Code 原生安装默认位置）
- `%APPDATA%\npm`（npm 全局 bin 常见落点）

实施时用 `[Environment]::GetEnvironmentVariable(..., "Machine")` 展开 `%VAR%`，避免 S4U 会话读不到用户 PATH。

### 4.4 旧 WSL 保活清理（Win11 侧自动）

在 `Ensure-ClautelKeepaliveTask` 之前执行：

```powershell
foreach ($old in @('DevEnvUbuntu-WSL-VMHolder','DevEnvUbuntu-WSL-Keepalive')) {
  if (Get-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $old -Confirm:$false
    Write-Host "  [Migrate] Removed obsolete task: $old" -ForegroundColor Yellow
  }
}
```

**不**自动删除 `%USERPROFILE%\.wslconfig` 或 `%LOCALAPPDATA%\DevEnvUbuntu`（与 Ubuntu 拆除 spec §4 一致，避免误伤用户自定义）。

### 4.5 菜单与派发

- 横幅行追加：`| 9. clautel`
- `switch` 增加 `"9" { & $TaskClautel }`
- `$selected` 解析：`all` → `@("1".."8")` **不含 9**；注释说明 `all,9`

### 4.6 与 polyglot 约束

- 不改 `###PS_START###` / `###PS_END###` 位置与字面量
- Watch 脚本内容避免非 ASCII（与 CLAUDE.md 一致）
- `dev_env.bat` 已自提权管理员；`Register-ScheduledTask` 无需额外 UAC

## 5. DevEnvUbuntu 拆除（引用，不展开）

实施计划应包含独立任务块，逐步执行 `2026-05-22-remove-clautel-design.md`：

- 删除 `modules/11-clautel.sh`、`modules/12-keepalive.sh`、`windows/*`
- 精简 `install.sh`、`modules/99-verify.sh`、`tests/smoke.sh`、`CLAUDE.md`、`README.md`
- 旧 spec 加废弃 banner；`grep -ri clautel` 验收（排除 `docs/` 与带 banner 的历史文件）

Win11 自动卸载任务计划 **不能替代** Ubuntu README §4 的 WSL/systemd 手动清理；两处文档应交叉链接。

## 6. 错误处理

| 场景 | 行为 |
|------|------|
| 无 node/npm | `throw`，红色提示菜单 2 |
| 无 claude | `throw`，提示官方安装文档 |
| `npm install -g` 失败 | 向上抛出，与其它 Task 一致 |
| 未 `clautel setup` | watch 脚本 SKIP，任务计划仍成功 |
| `clautel start` 失败 | 写 log `[ERR]`，下一心跳重试；不抛到任务计划层面（避免 SchTasks 标 Failed） |
| Mutex 未拿到（已有 watch 在跑） | 静默 `exit 0`，不写 ERROR |
| 注册任务失败 | `throw`（权限/策略问题） |

## 7. 校验标准

**DevEnvWin11（手工，管理员运行 `dev_env.bat` 选 9）：**

1. 无 Node 时选 9 → 明确报错。
2. 有 Node、无 claude → 明确报错。
3. 依赖齐全 → `npm install -g clautel@latest` 成功；`clautel --version` 为当前 npm latest；`Get-ScheduledTask DevEnvWin11-Clautel-Keepalive` 存在且 Enabled，Action 为 `wscript.exe`。
4. 若曾装 Ubuntu 保活 → `DevEnvUbuntu-WSL-*` 任务不存在。
5. **无黑框：** 手动 `schtasks /Run /TN DevEnvWin11-Clautel-Keepalive` 或等待心跳，期间**不应**出现控制台闪窗（可用屏幕录制或 Process Explorer 观察仅有 `wscript`/`powershell` Hidden/`node` daemon，无 `conhost` 前台窗）。
6. **排他：** 连续两次 `/Run`，日志仅一条 `[START]` 或第二条为 `[OK] already running` / Mutex 静默退出；任务历史无 Overlapping 失败。
7. `clautel setup` 后重启 OS → `clautel status` 为 running（验证 S4U + PATH 烘焙 + 静默 start）。

**DevEnvUbuntu：** 见 `remove-clautel-design.md` §5。

## 8. 不做的事

- 不在 Win11 安装器内执行 `irm claude.ai/install.ps1`
- 不用 NSSM / Windows Service 包装 clautel
- 不恢复 WSL VM Holder 或 `.wslconfig` 模板
- 不自动删除用户 `.wslconfig` / WSL 内 `clautel.service`（文档指引即可）
- `all` 不包含 9（避免误装）

## 9. 风险与缓解

| 风险 | 缓解 |
|------|------|
| S4U 任务读不到用户 PATH | 任务 Environment 显式烘焙 NVM + `.local\bin` + npm global |
| `clautel status` 输出格式变更 | 使用 `@latest` 可能随上游变；探活优先看 exit code，字符串 `running` 作辅 |
| `npm @latest` 不可复现 | 接受；菜单 9 每次升级；日志打印 `--version` 便于排障 |
| VBS/PS 仍偶发闪窗 | 坚持 wscript+vbHide+CreateNoWindow；若 `clautel start` 仍弹窗，改查 clautel 是否另有 GUI 子进程 |
| 配置路径猜错 | 实施前读 clautel 包内 config 路径，写入 spec 注释或代码常量 |
| 开机即启但用户未 setup | SKIP 日志，不刷失败；安装完成提示 setup |
| 两仓库 PR 不同步 | 实施计划注明：可同 PR  monorepo 式提交或两 PR 互相链接 |
