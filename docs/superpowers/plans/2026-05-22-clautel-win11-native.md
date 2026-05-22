# Win11 原生 clautel + Ubuntu 拆除保活 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 DevEnvWin11 增加菜单 `9. clautel`（`npm install -g clautel@latest` + 静默保活任务计划）；在 DevEnvUbuntu 拆除 clautel/WSL 保活，两仓库同步交付。

**Architecture:** Win11 沿用 `dev_env.bat` 单文件 `$Task` 模式；保活通过 `wscript.exe` → VBS（`vbHide`）→ 隐藏 PowerShell watch 脚本，任务计划 `AtStartup` S4U + 5 分钟心跳，Mutex + `clautel status` 双层排他。Ubuntu 侧为纯删除，执行既有 `DevEnvUbuntu/docs/superpowers/plans/2026-05-22-remove-clautel.md`。

**Tech Stack:** Windows batch + 内嵌 PowerShell；Ubuntu bash。无自动化测试框架。

**Reference specs:**
- Win11: [`docs/superpowers/specs/2026-05-22-clautel-win11-native-design.md`](../specs/2026-05-22-clautel-win11-native-design.md)
- Ubuntu: `D:\dev_env\DevEnvUbuntu\docs\superpowers\specs\2026-05-22-remove-clautel-design.md`

---

## File Structure

### DevEnvWin11（Modify）

| 文件 | 变更 |
|------|------|
| `dev_env.bat` | 新增 helper：`Get-DevEnvTaskPath`、`Remove-ObsoleteWslKeepaliveTasks`、`Write-ClautelWatchArtifacts`、`Ensure-ClautelKeepaliveTask`；新增 `$TaskClautel`；菜单/`switch` |
| `CLAUDE.md` | 菜单项 9、clautel 任务说明、保活任务名 |
| `AGENTS.md` | 与 `CLAUDE.md` 同步（若存在相同段落） |

**不动：** batch 半区（1–41 行）、`###PS_START###`/`###PS_END###` 标记、`pkg/`、`switch_*.bat`。

### DevEnvUbuntu（Delete + Edit）

见 **Part II** —— 执行 `DevEnvUbuntu/docs/superpowers/plans/2026-05-22-remove-clautel.md`（已写好，勿重复发明）。

---

## 背景：DevEnvWin11 无测试框架

与 [`2026-05-15-apktool-zipalign.md`](2026-05-15-apktool-zipalign.md) 相同：

1. **[PARSE-CHECK]** —— 解析 PS 载荷无语法错误。
2. **`Select-String` / dot-source 烟雾** —— 符号存在、函数可加载。
3. **手动验收** —— 管理员运行菜单 9、任务计划、无黑框、排他（见文末）。

**[PARSE-CHECK]（全文复用）：**

```powershell
cd D:\dev_env\DevEnvWin11
$lines = Get-Content dev_env.bat
$s = ($lines | Select-String '^###PS_START###$').LineNumber
$e = ($lines | Select-String '^###PS_END###$').LineNumber
$body = ($lines[($s)..($e-2)]) -join "`n"
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$errs)
if ($errs) { $errs | ForEach-Object { Write-Host "PARSE ERROR: $($_.Message)" }; exit 1 }
else { Write-Host "PS payload parses OK ($($e - $s - 1) lines)" }
```

**clautel 配置路径（已核实上游）：** `%USERPROFILE%\.clautel\config.json`（`clautel/dist/config.js`）。

**clautel status 输出：** `Status: running (PID …)` / `Not running.` / `Already running (PID …)` —— 探活用 `-match 'running'`（不区分大小写）。

---

# Part I — DevEnvWin11

## Task 1: 添加 `Get-DevEnvTaskPath` helper

**Files:**
- Modify: `dev_env.bat`（在 `Ensure-JavaOnPath` 函数之后、`# --- Task Functions ---` 之前插入）

- [ ] **Step 1: [PARSE-CHECK] 通过；确认 helper 尚不存在**

Run: `[PARSE-CHECK]`；`Select-String -Path dev_env.bat -Pattern 'Get-DevEnvTaskPath'`
Expected: parses OK；无匹配。

- [ ] **Step 2: 插入 PATH 解析函数**

在 `Ensure-JavaOnPath` 闭合 `}` 之后添加：

```powershell
function Get-DevEnvTaskPath {
    # Machine Path + common dev-env entries for Scheduled Task S4U / hidden child processes.
    $parts = @()
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($machine) { $parts += ($machine -split ';' | Where-Object { $_ }) }

    foreach ($pair in @(
        @{ Var = "NVM_HOME";    Sub = "" },
        @{ Var = "NVM_SYMLINK"; Sub = "" },
        @{ Var = "USERPROFILE"; Sub = ".local\bin" }
    )) {
        $root = [Environment]::GetEnvironmentVariable($pair.Var, "Machine")
        if (-not $root -and $pair.Var -eq "USERPROFILE") { $root = $env:USERPROFILE }
        if ($root) {
            $p = if ($pair.Sub) { Join-Path $root $pair.Sub } else { $root }
            if (Test-Path $p) { $parts += $p }
        }
    }

    $npmGlobal = Join-Path $env:APPDATA "npm"
    if (Test-Path $npmGlobal) { $parts += $npmGlobal }

    $nodeDir = "D:\dev_env\nodejs"
    if (Test-Path $nodeDir) { $parts += $nodeDir }

    ($parts | Select-Object -Unique) -join ';'
}
```

- [ ] **Step 3: [PARSE-CHECK]**

Expected: `PS payload parses OK`

---

## Task 2: 添加 `Remove-ObsoleteWslKeepaliveTasks`

**Files:**
- Modify: `dev_env.bat`（紧接 `Get-DevEnvTaskPath` 之后）

- [ ] **Step 1: 插入迁移函数**

```powershell
function Remove-ObsoleteWslKeepaliveTasks {
    foreach ($old in @('DevEnvUbuntu-WSL-VMHolder', 'DevEnvUbuntu-WSL-Keepalive')) {
        $t = Get-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue
        if ($t) {
            Unregister-ScheduledTask -TaskName $old -Confirm:$false
            Write-Host "  [Migrate] Removed obsolete task: $old" -ForegroundColor Yellow
        }
    }
}
```

- [ ] **Step 2: [PARSE-CHECK]**

---

## Task 3: 添加 `Write-ClautelWatchArtifacts`

**Files:**
- Modify: `dev_env.bat`（紧接上一函数之后）

- [ ] **Step 1: 插入写 VBS + watch.ps1 的函数**

```powershell
function Write-ClautelWatchArtifacts {
    $dir = Join-Path $env:LOCALAPPDATA "DevEnvWin11"
    if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $watchPs1 = Join-Path $dir "clautel-watch.ps1"
    $launchVbs = Join-Path $dir "clautel-watch-launch.vbs"
    $taskPath = Get-DevEnvTaskPath

    $watchContent = @'
$ErrorActionPreference = "Stop"
$logFile = Join-Path (Join-Path $env:LOCALAPPDATA "DevEnvWin11") "clautel-watch.log"
function Append-ClautelLog([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    if ((Get-Item $logFile).Length -gt 524288) {
        $tail = Get-Content $logFile -Tail 4096
        Set-Content -Path $logFile -Value $tail -Encoding UTF8
    }
}
$mutexName = "Global\DevEnvWin11-Clautel-Watch"
$created = $false
$mtx = New-Object System.Threading.Mutex($false, $mutexName, [ref]$created)
if (-not $created) { exit 0 }
try {
    $cfg = Join-Path $env:USERPROFILE ".clautel\config.json"
    if (-not (Test-Path $cfg)) {
        Append-ClautelLog "[SKIP] clautel not configured; run clautel setup"
        exit 0
    }
    $env:PATH = "TASK_PATH_PLACEHOLDER"
    $st = & clautel status 2>&1 | Out-String
    if ($st -match 'running') {
        Append-ClautelLog "[OK] already running"
        exit 0
    }
    $npmRoot = & npm root -g 2>&1
    if ($LASTEXITCODE -ne 0) { throw "npm root -g failed: $npmRoot" }
    $cliJs = Join-Path ($npmRoot.Trim()) "clautel\dist\cli.js"
    if (-not (Test-Path $cliJs)) { throw "clautel cli not found at $cliJs" }
    $nodeExe = Join-Path (Split-Path (Get-Command node).Source -Parent) "node.exe"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nodeExe
    $psi.Arguments = "`"$cliJs`" start"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $null = [System.Diagnostics.Process]::Start($psi)
    Append-ClautelLog "[START] clautel daemon (hidden node)"
} catch {
    Append-ClautelLog "[ERR] $($_.Exception.Message)"
    exit 0
} finally {
    $mtx.ReleaseMutex() | Out-Null
}
'@
    $watchContent = $watchContent.Replace('TASK_PATH_PLACEHOLDER', $taskPath.Replace('"', '""'))
    Set-Content -Path $watchPs1 -Value $watchContent -Encoding ASCII

    $vbsContent = @"
' DevEnvWin11 clautel watch launcher (no console flash)
ps1 = "$($watchPs1 -replace '\\', '\\')"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
CreateObject("WScript.Shell").Run cmd, 0, False
"@
    Set-Content -Path $launchVbs -Value $vbsContent -Encoding ASCII
    Write-Host "  [Keepalive] Wrote $watchPs1" -ForegroundColor Green
    Write-Host "  [Keepalive] Wrote $launchVbs" -ForegroundColor Green
}
```

- [ ] **Step 2: [PARSE-CHECK]**

---

## Task 4: 添加 `Ensure-ClautelKeepaliveTask`

**Files:**
- Modify: `dev_env.bat`（紧接 `Write-ClautelWatchArtifacts` 之后）

- [ ] **Step 1: 插入注册任务计划函数**

```powershell
function Ensure-ClautelKeepaliveTask {
    $taskName = "DevEnvWin11-Clautel-Keepalive"
    $dir = Join-Path $env:LOCALAPPDATA "DevEnvWin11"
    $launchVbs = Join-Path $dir "clautel-watch-launch.vbs"
    if (!(Test-Path $launchVbs)) { throw "Missing $launchVbs; call Write-ClautelWatchArtifacts first" }

    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    $action = New-ScheduledTaskAction -Execute $wscript -Argument "//B //Nologo `"$launchVbs`""

    $triggerBoot = New-ScheduledTaskTrigger -AtStartup
    $triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)

    $principalName = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $principalName -LogonType S4U -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

    $taskPath = Get-DevEnvTaskPath
    $envPairs = @([System.Collections.Generic.Dictionary[string,string]]::new())
    $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $dict['PATH'] = $taskPath
    $task = New-ScheduledTask -Action $action -Trigger @($triggerBoot, $triggerRepeat) -Principal $principal -Settings $settings

    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
    Write-Host "  [Keepalive] Registered: $taskName (AtStartup + 5m, S4U, Hidden)" -ForegroundColor Green
}
```

**注意：** 若 `Register-ScheduledTask` 对 `-Once -At (Get-Date).Date` 重复触发器报错，改用 XML 或 `schtasks` 备选；实施时以本机 `Get-ScheduledTask DevEnvWin11-Clautel-Keepalive | fl` 为准调整。

- [ ] **Step 2: [PARSE-CHECK]**

---

## Task 5: 添加 `$TaskClautel`

**Files:**
- Modify: `dev_env.bat`（在 `$TaskZipalign` 之后、`# --- Execution ---` 之前）

- [ ] **Step 1: 插入任务脚本块**

```powershell
$TaskClautel = {
    Write-Host "`n>> clautel (npm latest + keepalive)" -ForegroundColor Cyan

    if (-not (Test-CommandAvailable "node")) {
        throw "Node.js required. Install menu 2 (Node) first."
    }
    if (-not (Test-CommandAvailable "npm")) {
        throw "npm required. Install menu 2 (Node) first."
    }
    if (-not (Test-CommandAvailable "claude")) {
        throw "Claude Code CLI (claude) required. Install from https://code.claude.com/docs/en/setup"
    }

    Write-Host "  [npm] install -g clautel@latest ..." -ForegroundColor White
    & npm install -g clautel@latest
    if ($LASTEXITCODE -ne 0) { throw "npm install -g clautel@latest failed (exit $LASTEXITCODE)" }

    $ver = & clautel --version 2>&1
    Write-Host "  [OK] clautel $ver" -ForegroundColor Green

    Remove-ObsoleteWslKeepaliveTasks
    Write-ClautelWatchArtifacts
    Ensure-ClautelKeepaliveTask

    $cfg = Join-Path $env:USERPROFILE ".clautel\config.json"
    if (-not (Test-Path $cfg)) {
        Write-Host "  [Next] Run: clautel setup" -ForegroundColor Yellow
        Write-Host "  [Next] Then: clautel activate <license-key>" -ForegroundColor Yellow
    }
}
```

- [ ] **Step 2: [PARSE-CHECK]**

---

## Task 6: 菜单与 dispatch

**Files:**
- Modify: `dev_env.bat`（`# --- Execution ---` 区）

- [ ] **Step 1: 更新菜单横幅**

old_string:
```
Write-Host " 1. Java(8+17) | 2. Node | 3. Python | 4. Maven | 5. Git | 6. Android | 7. apktool | 8. zipalign | all. All"
```
new_string:
```
Write-Host " 1. Java(8+17) | 2. Node | 3. Python | 4. Maven | 5. Git | 6. Android | 7. apktool | 8. zipalign | 9. clautel | all. All (1-8; add ,9 for clautel)"
```

- [ ] **Step 2: 确认 `all` 不含 9**

`$selected = if ($choice -eq "all") { @("1","2","3","4","5","6","7","8") } else { $choice -split "," }`
（已符合则跳过编辑。）

- [ ] **Step 3: switch 增加 9**

在 `"8" { & $TaskZipalign }` 后增加：
```
            "9" { & $TaskClautel }
```

- [ ] **Step 4: [PARSE-CHECK] + 符号烟雾**

```powershell
# [PARSE-CHECK]
$lines = Get-Content dev_env.bat
$s = ($lines | Select-String '^###PS_START###$').LineNumber
$e = ($lines | Select-String '^###PS_END###$').LineNumber
$body = ($lines[($s)..($e-2)]) -join "`n"
$cut = ($body -split '# --- Execution ---')[0]
Invoke-Expression $cut
@( 'Get-DevEnvTaskPath','Remove-ObsoleteWslKeepaliveTasks','Write-ClautelWatchArtifacts','Ensure-ClautelKeepaliveTask',$TaskClautel ) | ForEach-Object {
  if (-not (Get-Variable -Name $_ -ErrorAction SilentlyContinue)) { throw "Missing: $_" }
}
Write-Host "Dot-source smoke OK"
```

---

## Task 7: 更新 CLAUDE.md / AGENTS.md

**Files:**
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`（若菜单/architecture 段落镜像 CLAUDE.md）

- [ ] **Step 1: 在菜单说明中加入 `9` clautel**

补充要点：
- 依赖 Node（菜单 2）+ `claude` CLI
- `npm install -g clautel@latest` 每次选 9 执行
- 任务计划 `DevEnvWin11-Clautel-Keepalive`（wscript → VBS → 隐藏 PS）
- `all` 不含 9；自动移除 `DevEnvUbuntu-WSL-*` 旧任务

- [ ] **Step 2: AGENTS.md 同步**（同上文，避免两文件漂移）

---

## Task 8: 更新 Win11 spec 状态（可选文档）

**Files:**
- Modify: `docs/superpowers/specs/2026-05-22-clautel-win11-native-design.md` 首行状态 → `计划已写入 2026-05-22-clautel-win11-native.md`

---

# Part II — DevEnvUbuntu（执行既有计划）

**不要在本仓库新建 Ubuntu 任务细节** —— 在 `D:\dev_env\DevEnvUbuntu` 工作区按顺序执行：

[`D:\dev_env\DevEnvUbuntu\docs\superpowers\plans\2026-05-22-remove-clautel.md`](../../DevEnvUbuntu/docs/superpowers/plans/2026-05-22-remove-clautel.md)

- [ ] **Step 1:** 完成该计划 Task 1–N（删除模块、`windows/`、`install.sh` 精简、文档 banner、`grep` 验收）。
- [ ] **Step 2:** 验收命令（在 DevEnvUbuntu 根目录）：

```bash
grep -ri clautel . --exclude-dir=docs 2>/dev/null | grep -v '2026-05-22-remove-clautel' || true
# 期望：modules/install/tests/windows 无 clautel 命中
bash tests/smoke.sh
```

- [ ] **Step 3:** README「v4 升级」段与 Win11 spec 交叉链接。

---

## 手动验收（DevEnvWin11）

在**已安装 Node（菜单 2）且 `claude` 在 PATH** 的机器上，非管理员打开 `dev_env.bat`（UAC 提权后）：

| # | 操作 | 期望 |
|---|------|------|
| 1 | 选 `9` | `npm install -g clautel@latest` 成功；打印版本 |
| 2 | `Get-ScheduledTask -TaskName DevEnvWin11-Clautel-Keepalive` | State Ready/Running；Actions 为 `wscript.exe` |
| 3 | 无 `DevEnvUbuntu-WSL-VMHolder` / `Keepalive` 任务 | 已 Unregister |
| 4 | `schtasks /Run /TN DevEnvWin11-Clautel-Keepalive` | **无黑色控制台闪窗**；`%LOCALAPPDATA%\DevEnvWin11\clautel-watch.log` 有 `[SKIP]` 或 `[OK]`/`[START]` |
| 5 | 连续 `/Run` 两次 | 第二条为 Mutex 退出或 `[OK] already running`，无重复 daemon |
| 6 | `clautel setup` + 重启 | 重启后 `clautel status` → `running` |

---

## Plan self-review（已完成）

| 检查项 | 结果 |
|--------|------|
| Spec: latest clautel | Task 5 `npm install -g clautel@latest` |
| Spec: 无黑框 | Task 3 VBS vbHide + Task 4 Hidden + node CreateNoWindow |
| Spec: 排他 | Task 3 Mutex + status + Task 4 IgnoreNew |
| Spec: 卸旧 WSL 任务 | Task 2 + Task 5 调用 |
| Spec: Ubuntu 拆除 | Part II 引用既有 plan |
| 无 TBD | 触发器若 API 失败有实施备注 |

---

## 建议提交顺序（用户要求 commit 时再执行）

1. `feat(win11): add clautel task 9 with silent keepalive scheduled task`
2. `docs(win11): clautel native design + implementation plan`
3. DevEnvUbuntu 仓库：`chore: remove clautel and WSL keepalive`（按 remove-clautel 计划分批 commit）
