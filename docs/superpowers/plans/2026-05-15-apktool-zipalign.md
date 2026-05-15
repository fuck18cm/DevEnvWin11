# apktool + zipalign 安装任务 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `dev_env.bat` 中新增 `7. apktool` 和 `8. zipalign` 两个安装任务，把这两个命令装到 `D:\dev_env` 并注册到 Machine 作用域 PATH。

**Architecture:** 沿用 repo 既有的 per-tool `$Task` 脚本块模式（skip-if-present → `Download-Official` → 安装 → 注册 env）。把 `TaskAndroid` 里下载 cmdline-tools 和 Java-on-PATH 的逻辑抽成两个共享 helper（`Ensure-AndroidCmdlineTools`、`Ensure-JavaOnPath`），供 `TaskAndroid` 和新的 `TaskZipalign` 复用。

**Tech Stack:** Windows batch + 内嵌 PowerShell（bat-wraps-PowerShell polyglot）。无构建、无测试套件。

---

## 背景：这个 repo 没有测试框架

`dev_env.bat` 是单文件交付物，没有 build / test / 包管理器。本计划的「测试」用两种自动化手段代替：

1. **PS 载荷语法解析检查** —— 提取 `###PS_START###`/`###PS_END###` 之间的 PowerShell 载荷，用 `[System.Management.Automation.Language.Parser]` 解析，确认无语法错误。
2. **`Select-String` 断言** —— 确认具体改动文本已写入。

最终 Task 6 额外做一次「dot-source 烟雾测试」：加载定义段（`# --- Execution ---` 之前的全部内容），断言新函数、新 `$Task` 脚本块、新 `$v`/`$paths`/`$urls` 项都能解析。功能性的交互式安装验证是手动的，列在计划末尾的「手动验收」一节，由用户在提权 shell 里执行。

**贯穿全程的解析检查命令**（多处复用，下文记作 `[PARSE-CHECK]`）：

```powershell
$lines = Get-Content dev_env.bat
$s = ($lines | Select-String '^###PS_START###$').LineNumber
$e = ($lines | Select-String '^###PS_END###$').LineNumber
$body = ($lines[$s..($e-2)]) -join "`n"
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$errs)
if ($errs) { $errs | ForEach-Object { Write-Host "PARSE ERROR: $($_.Message)" }; exit 1 }
else { Write-Host "PS payload parses OK ($($e - $s - 1) lines)" }
```

`$s` 是 `###PS_START###` 的 1-based 行号，作 0-based 索引正好指向标记的下一行；`$e-2` 作 0-based 索引指向 `###PS_END###` 的上一行。

---

## File Structure

只动一个文件：

- **Modify: `dev_env.bat`** —— 全部改动都在 `###PS_START###`/`###PS_END###` 之间的 PowerShell 载荷内。具体：
  - `$v` / `$paths` / `$urls` 三个哈希表各加 2 行（Task 1）
  - helper 函数区新增 `Ensure-AndroidCmdlineTools`、`Ensure-JavaOnPath`（Task 2）
  - `$TaskAndroid` 改造为调用 helper（Task 3）
  - 新增 `$TaskApktool`（Task 4）
  - 新增 `$TaskZipalign`（Task 5）
  - 菜单文案 / `$selected` / `switch` dispatch（Task 6）

**不动**：batch 半区（1–41 行）、`###PS_START###`/`###PS_END###` 标记行、`title` 行、`pkg/`、`switch_jdk.bat`、`switch_python.bat`、磁盘上现存的扁平 `D:\dev_env\apktool\apktool.jar`。

---

## Task 1: 给 $v / $paths / $urls 加新条目

**Files:**
- Modify: `dev_env.bat`（`$v` 54–60 行、`$paths` 63–73 行、`$urls` 75–84 行）

- [ ] **Step 1: 确认起点 —— 解析检查通过、新条目尚不存在**

Run:
```powershell
# [PARSE-CHECK]（见上文）
Select-String -Path dev_env.bat -Pattern 'Apktool|BuildTools'
```
Expected: `[PARSE-CHECK]` 输出 `PS payload parses OK`；`Select-String` 无任何匹配（新条目还没加）。

- [ ] **Step 2: 在 `$v` 哈希表末尾加一行**

用 Edit 工具，old_string：
```
    TGit    = "2.15.0.0";   Android = "11076708"
}
```
new_string：
```
    TGit    = "2.15.0.0";   Android = "11076708"
    Apktool = "3.0.2";      BuildTools = "35.0.0"
}
```

- [ ] **Step 3: 在 `$paths` 哈希表末尾加两行**

用 Edit 工具，old_string：
```
    Android = "$base\android_sdk"
}
```
new_string：
```
    Android = "$base\android_sdk"
    Apktool    = "$base\apktool\$($v.Apktool)"
    BuildTools = "$base\android_sdk\build-tools\$($v.BuildTools)"
}
```

- [ ] **Step 4: 在 `$urls` 哈希表末尾加两行**

用 Edit 工具，old_string：
```
    Android = "https://dl.google.com/android/repository/commandlinetools-win-$($v.Android)_latest.zip"
}
```
new_string：
```
    Android = "https://dl.google.com/android/repository/commandlinetools-win-$($v.Android)_latest.zip"
    ApktoolJar = "https://github.com/iBotPeaches/Apktool/releases/download/v$($v.Apktool)/apktool_$($v.Apktool).jar"
    ApktoolBat = "https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/windows/apktool.bat"
}
```

- [ ] **Step 5: 解析检查 + 断言新条目已写入**

Run:
```powershell
# [PARSE-CHECK]（见上文）
Select-String -Path dev_env.bat -Pattern 'Apktool\s*=|BuildTools\s*=|ApktoolJar|ApktoolBat'
```
Expected: `PS payload parses OK`；`Select-String` 命中 6 处（`$v` 里 2 个、`$paths` 里 2 个、`$urls` 里 2 个）。

- [ ] **Step 6: Commit**

```powershell
git add dev_env.bat
git commit -m "feat: 为 apktool/zipalign 添加 `$v/`$paths/`$urls 条目"
```

---

## Task 2: 新增两个共享 helper 函数

**Files:**
- Modify: `dev_env.bat`（helper 函数区，`Merge-SplitFiles` 之后 / `# --- Task Functions ---` 之前，约 150–152 行）

- [ ] **Step 1: 确认起点 —— 两个函数尚不存在**

Run:
```powershell
Select-String -Path dev_env.bat -Pattern 'function Ensure-AndroidCmdlineTools|function Ensure-JavaOnPath'
```
Expected: 无匹配。

- [ ] **Step 2: 在 `Merge-SplitFiles` 和 `# --- Task Functions ---` 之间插入两个函数**

用 Edit 工具，old_string：
```
    } finally { $out.Close() }
}

# --- Task Functions ---
```
new_string：
```
    } finally { $out.Close() }
}

function Ensure-AndroidCmdlineTools {
    # Ensures android_sdk\cmdline-tools\latest exists; returns the sdkmanager.bat path.
    # Does NOT check for Java - callers run Ensure-JavaOnPath only when they actually
    # need to invoke sdkmanager (not on the skip path).
    $lat = "$($paths.Android)\cmdline-tools\latest"
    if (!(Test-Path $lat)) {
        $f = Download-Official $urls.Android "sdk.zip"
        Expand-Archive $f -DestinationPath "$tempCache\sdk" -Force
        New-Item -ItemType Directory -Path $lat -Force | Out-Null
        Copy-Item "$tempCache\sdk\cmdline-tools\*" $lat -Recurse -Force
    }
    $sdk = Join-Path $lat "bin\sdkmanager.bat"
    if (!(Test-Path $sdk)) { throw "sdkmanager.bat not found at $sdk" }
    return $sdk
}

function Ensure-JavaOnPath {
    # sdkmanager requires Java on PATH for the current process. Fall back to the
    # bundled JDKs (prefer 8, then 17); throw if neither is installed.
    if (-not (Test-CommandAvailable "java")) {
        if (Test-Path "$($paths.Java8)\bin\java.exe") {
            $env:Path = "$($paths.Java8)\bin;$env:Path"
        } elseif (Test-Path "$($paths.Java17)\bin\java.exe") {
            $env:Path = "$($paths.Java17)\bin;$env:Path"
        } else {
            throw "Java not found. Install Java (option 1) first."
        }
    }
}

# --- Task Functions ---
```

- [ ] **Step 3: 解析检查 + 断言函数已写入**

Run:
```powershell
# [PARSE-CHECK]（见上文）
Select-String -Path dev_env.bat -Pattern 'function Ensure-AndroidCmdlineTools|function Ensure-JavaOnPath'
```
Expected: `PS payload parses OK`；`Select-String` 命中 2 处。

- [ ] **Step 4: Commit**

```powershell
git add dev_env.bat
git commit -m "refactor: 抽出 Ensure-AndroidCmdlineTools / Ensure-JavaOnPath helper"
```

---

## Task 3: 改造 TaskAndroid 调用 helper

**Files:**
- Modify: `dev_env.bat`（`$TaskAndroid` 脚本块，393–437 行）

行为不变，只是把内联的「下载 cmdline-tools」和「Java-on-PATH 回退」换成 Task 2 的 helper。注意 env 注册仍在 adb skip 检查之前；`Ensure-JavaOnPath` 仍在 skip 检查之后调用（skip 时不应因缺 Java 报错）。

- [ ] **Step 1: 确认起点 —— TaskAndroid 仍是内联版本**

Run:
```powershell
Select-String -Path dev_env.bat -Pattern '\$lat = "\$\(\$paths\.Android\)\\cmdline-tools\\latest"'
```
Expected: 命中 1 处（内联版本的 `$lat` 赋值还在）。

- [ ] **Step 2: 整块替换 `$TaskAndroid`**

用 Edit 工具，old_string（当前完整的 `$TaskAndroid` 脚本块）：
```
$TaskAndroid = {
    Write-Host "`n>> Android SDK" -ForegroundColor Cyan

    $adb = "$($paths.Android)\platform-tools\adb.exe"
    $lat = "$($paths.Android)\cmdline-tools\latest"

    if (!(Test-Path $lat)) {
        $f = Download-Official $urls.Android "sdk.zip"
        Expand-Archive $f -DestinationPath "$tempCache\sdk" -Force
        New-Item -ItemType Directory -Path $lat -Force | Out-Null
        Copy-Item "$tempCache\sdk\cmdline-tools\*" $lat -Recurse -Force
    }

    Set-EnvVar "ANDROID_HOME" $paths.Android
    Add-PathVar "%ANDROID_HOME%\cmdline-tools\latest\bin" "$lat\bin"
    Add-PathVar "%ANDROID_HOME%\platform-tools" "$($paths.Android)\platform-tools"

    if (Test-Path $adb) {
        Write-Host "  [Skip] adb already installed." -ForegroundColor Yellow
        return
    }

    $sdk = Join-Path $lat "bin\sdkmanager.bat"
    if (!(Test-Path $sdk)) { throw "sdkmanager.bat not found at $sdk" }

    # sdkmanager requires Java on PATH for the current process
    if (-not (Test-CommandAvailable "java")) {
        if (Test-Path "$($paths.Java8)\bin\java.exe") {
            $env:Path = "$($paths.Java8)\bin;$env:Path"
        } elseif (Test-Path "$($paths.Java17)\bin\java.exe") {
            $env:Path = "$($paths.Java17)\bin;$env:Path"
        } else {
            throw "Java not found. Install Java (option 1) first, then re-run option 6."
        }
    }

    Write-Host "  [SDK] Accepting licenses..." -ForegroundColor White
    cmd /c "(for /l %i in (1,1,30) do @echo y) | `"$sdk`" --sdk_root=`"$($paths.Android)`" --licenses" | Out-Null

    Write-Host "  [SDK] Installing platform-tools..." -ForegroundColor White
    cmd /c "echo y | `"$sdk`" --sdk_root=`"$($paths.Android)`" `"platform-tools`""

    if (!(Test-Path $adb)) { throw "platform-tools install failed; adb.exe not found at $adb" }
    Write-Host "  [SDK] adb installed at $adb" -ForegroundColor Green
}
```
new_string：
```
$TaskAndroid = {
    Write-Host "`n>> Android SDK" -ForegroundColor Cyan

    $adb = "$($paths.Android)\platform-tools\adb.exe"
    $sdk = Ensure-AndroidCmdlineTools

    Set-EnvVar "ANDROID_HOME" $paths.Android
    Add-PathVar "%ANDROID_HOME%\cmdline-tools\latest\bin" "$($paths.Android)\cmdline-tools\latest\bin"
    Add-PathVar "%ANDROID_HOME%\platform-tools" "$($paths.Android)\platform-tools"

    if (Test-Path $adb) {
        Write-Host "  [Skip] adb already installed." -ForegroundColor Yellow
        return
    }

    Ensure-JavaOnPath

    Write-Host "  [SDK] Accepting licenses..." -ForegroundColor White
    cmd /c "(for /l %i in (1,1,30) do @echo y) | `"$sdk`" --sdk_root=`"$($paths.Android)`" --licenses" | Out-Null

    Write-Host "  [SDK] Installing platform-tools..." -ForegroundColor White
    cmd /c "echo y | `"$sdk`" --sdk_root=`"$($paths.Android)`" `"platform-tools`""

    if (!(Test-Path $adb)) { throw "platform-tools install failed; adb.exe not found at $adb" }
    Write-Host "  [SDK] adb installed at $adb" -ForegroundColor Green
}
```

- [ ] **Step 3: 解析检查 + 断言改造完成**

Run:
```powershell
# [PARSE-CHECK]（见上文）
Select-String -Path dev_env.bat -Pattern '\$sdk = Ensure-AndroidCmdlineTools|Ensure-JavaOnPath'
```
Expected: `PS payload parses OK`；`Select-String` 命中 3 处（`Ensure-AndroidCmdlineTools` 在 helper 定义 + TaskAndroid 调用；`Ensure-JavaOnPath` 在 helper 定义；注意此命令同时匹配定义和调用 —— TaskAndroid 里应能看到 `$sdk = Ensure-AndroidCmdlineTools` 和 `Ensure-JavaOnPath` 各一行）。再单独确认内联版本已消失：

```powershell
Select-String -Path dev_env.bat -Pattern 'then re-run option 6'
```
Expected: 无匹配（旧的内联报错信息已被移除）。

- [ ] **Step 4: Commit**

```powershell
git add dev_env.bat
git commit -m "refactor: TaskAndroid 改用共享 helper，行为不变"
```

---

## Task 4: 新增 $TaskApktool

**Files:**
- Modify: `dev_env.bat`（在 `# --- Execution ---` 之前插入新脚本块）

- [ ] **Step 1: 确认起点 —— $TaskApktool 尚不存在**

Run:
```powershell
Select-String -Path dev_env.bat -Pattern '\$TaskApktool'
```
Expected: 无匹配。

- [ ] **Step 2: 在 `# --- Execution ---` 之前插入 `$TaskApktool`**

用 Edit 工具，old_string：
```

# --- Execution ---
```
new_string：
```

$TaskApktool = {
    Write-Host "`n>> apktool" -ForegroundColor Cyan

    $apkJar = "$($paths.Apktool)\apktool_$($v.Apktool).jar"
    $apkBat = "$($paths.Apktool)\apktool.bat"

    if (Test-Path $apkJar) {
        Write-Host "  [Skip] apktool $($v.Apktool) already at $($paths.Apktool)" -ForegroundColor Yellow
    } else {
        New-Item -ItemType Directory -Path $paths.Apktool -Force | Out-Null
        $jar = Download-Official $urls.ApktoolJar "apktool_$($v.Apktool).jar"
        Copy-Item $jar $apkJar -Force
        $bat = Download-Official $urls.ApktoolBat "apktool.bat"
        Copy-Item $bat $apkBat -Force
        if (!(Test-Path $apkJar)) { throw "apktool install failed at $($paths.Apktool)" }
        Write-Host "  [Install] apktool $($v.Apktool) -> $($paths.Apktool)" -ForegroundColor Green
    }

    Set-EnvVar "APKTOOL_HOME" $paths.Apktool
    Add-PathVar "%APKTOOL_HOME%" $paths.Apktool

    # apktool 3.x needs Java 11+; this repo defaults JAVA_HOME to JDK 8
    $jh = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
    if ($jh -eq $paths.Java8) {
        Write-Host "  [Note] apktool $($v.Apktool) needs Java 11+, but JAVA_HOME is JDK 8. Run: switch_jdk.bat 17" -ForegroundColor Yellow
    } else {
        Write-Host "  [Note] apktool $($v.Apktool) requires Java 11+ on PATH." -ForegroundColor Yellow
    }
}

# --- Execution ---
```

- [ ] **Step 3: 解析检查 + 断言 $TaskApktool 已写入**

Run:
```powershell
# [PARSE-CHECK]（见上文）
Select-String -Path dev_env.bat -Pattern '\$TaskApktool = \{|APKTOOL_HOME'
```
Expected: `PS payload parses OK`；`Select-String` 命中 3 处（`$TaskApktool = {` 1 处、`APKTOOL_HOME` 2 处 —— `Set-EnvVar` 和 `Add-PathVar` 各一行）。

- [ ] **Step 4: Commit**

```powershell
git add dev_env.bat
git commit -m "feat: 新增 TaskApktool 安装任务"
```

---

## Task 5: 新增 $TaskZipalign

**Files:**
- Modify: `dev_env.bat`（在 `# --- Execution ---` 之前、`$TaskApktool` 之后插入新脚本块）

- [ ] **Step 1: 确认起点 —— $TaskZipalign 尚不存在**

Run:
```powershell
Select-String -Path dev_env.bat -Pattern '\$TaskZipalign'
```
Expected: 无匹配。

- [ ] **Step 2: 在 `# --- Execution ---` 之前插入 `$TaskZipalign`**

用 Edit 工具，old_string：
```

# --- Execution ---
```
new_string：
```

$TaskZipalign = {
    Write-Host "`n>> zipalign (Android build-tools $($v.BuildTools))" -ForegroundColor Cyan

    $zipalign = "$($paths.BuildTools)\zipalign.exe"
    $sdk = Ensure-AndroidCmdlineTools

    Set-EnvVar "ANDROID_HOME" $paths.Android
    Add-PathVar "%ANDROID_HOME%\build-tools\$($v.BuildTools)" $paths.BuildTools

    if (Test-Path $zipalign) {
        Write-Host "  [Skip] zipalign already at $($paths.BuildTools)" -ForegroundColor Yellow
        return
    }

    Ensure-JavaOnPath

    Write-Host "  [SDK] Accepting licenses..." -ForegroundColor White
    cmd /c "(for /l %i in (1,1,30) do @echo y) | `"$sdk`" --sdk_root=`"$($paths.Android)`" --licenses" | Out-Null

    Write-Host "  [SDK] Installing build-tools;$($v.BuildTools)..." -ForegroundColor White
    cmd /c "echo y | `"$sdk`" --sdk_root=`"$($paths.Android)`" `"build-tools;$($v.BuildTools)`""

    if (!(Test-Path $zipalign)) { throw "build-tools install failed; zipalign.exe not found at $zipalign" }
    Write-Host "  [SDK] zipalign installed at $zipalign" -ForegroundColor Green
}

# --- Execution ---
```

注：这一步把 `$TaskZipalign` 插在 `$TaskApktool`（Task 4 已插入）和 `# --- Execution ---` 之间。最终顺序为 `$TaskApktool` → `$TaskZipalign` → `# --- Execution ---`。

- [ ] **Step 3: 解析检查 + 断言 $TaskZipalign 已写入**

Run:
```powershell
# [PARSE-CHECK]（见上文）
Select-String -Path dev_env.bat -Pattern '\$TaskZipalign = \{|build-tools;\$\(\$v\.BuildTools\)'
```
Expected: `PS payload parses OK`；`Select-String` 命中 2 处（`$TaskZipalign = {` 1 处、`build-tools;$($v.BuildTools)` 在 sdkmanager 调用里 1 处）。

- [ ] **Step 4: Commit**

```powershell
git add dev_env.bat
git commit -m "feat: 新增 TaskZipalign 安装任务"
```

---

## Task 6: 接入菜单、all 分支、switch dispatch

**Files:**
- Modify: `dev_env.bat`（菜单文案 445 行、`$selected` 449 行、`switch` 456–463 行）

- [ ] **Step 1: 确认起点 —— 菜单还没有 7/8**

Run:
```powershell
Select-String -Path dev_env.bat -Pattern '7\. apktool|& \$TaskApktool|& \$TaskZipalign'
```
Expected: 无匹配。

- [ ] **Step 2: 改菜单文案**

用 Edit 工具，old_string：
```
Write-Host " 1. Java(8+17) | 2. Node | 3. Python | 4. Maven | 5. Git | 6. Android | all. All"
```
new_string：
```
Write-Host " 1. Java(8+17) | 2. Node | 3. Python | 4. Maven | 5. Git | 6. Android | 7. apktool | 8. zipalign | all. All"
```

- [ ] **Step 3: 改 `all` 分支**

用 Edit 工具，old_string：
```
$selected = if ($choice -eq "all") { @("1","2","3","4","5","6") } else { $choice -split "," }
```
new_string：
```
$selected = if ($choice -eq "all") { @("1","2","3","4","5","6","7","8") } else { $choice -split "," }
```

- [ ] **Step 4: 给 `switch` 加两个 case**

用 Edit 工具，old_string：
```
            "5" { & $TaskGit }
            "6" { & $TaskAndroid }
        }
```
new_string：
```
            "5" { & $TaskGit }
            "6" { & $TaskAndroid }
            "7" { & $TaskApktool }
            "8" { & $TaskZipalign }
        }
```

- [ ] **Step 5: 解析检查 + 断言接入完成**

Run:
```powershell
# [PARSE-CHECK]（见上文）
Select-String -Path dev_env.bat -Pattern '7\. apktool | 8\. zipalign|"7" \{ & \$TaskApktool \}|"8" \{ & \$TaskZipalign \}|"1","2","3","4","5","6","7","8"'
```
Expected: `PS payload parses OK`；`Select-String` 命中菜单文案 1 处、`all` 分支 1 处、两个 switch case 各 1 处。

- [ ] **Step 6: dot-source 烟雾测试 —— 确认整个定义段加载、新符号全部解析**

Run:
```powershell
$lines = Get-Content dev_env.bat
$s = ($lines | Select-String '^###PS_START###$').LineNumber
$execLine = ($lines | Select-String '^# --- Execution ---$').LineNumber
$defs = ($lines[$s..($execLine-2)]) -join "`n"
. ([scriptblock]::Create($defs))
@(
  @{ n='Ensure-AndroidCmdlineTools'; ok = $null -ne (Get-Command Ensure-AndroidCmdlineTools -EA SilentlyContinue) }
  @{ n='Ensure-JavaOnPath';          ok = $null -ne (Get-Command Ensure-JavaOnPath -EA SilentlyContinue) }
  @{ n='$TaskApktool scriptblock';   ok = $TaskApktool -is [scriptblock] }
  @{ n='$TaskZipalign scriptblock';  ok = $TaskZipalign -is [scriptblock] }
  @{ n='$v.Apktool = 3.0.2';         ok = $v.Apktool -eq '3.0.2' }
  @{ n='$v.BuildTools = 35.0.0';     ok = $v.BuildTools -eq '35.0.0' }
  @{ n='$paths.Apktool';             ok = $paths.Apktool -eq 'D:\dev_env\apktool\3.0.2' }
  @{ n='$paths.BuildTools';          ok = $paths.BuildTools -eq 'D:\dev_env\android_sdk\build-tools\35.0.0' }
  @{ n='$urls.ApktoolJar';           ok = $urls.ApktoolJar -eq 'https://github.com/iBotPeaches/Apktool/releases/download/v3.0.2/apktool_3.0.2.jar' }
  @{ n='$urls.ApktoolBat';           ok = $urls.ApktoolBat -eq 'https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/windows/apktool.bat' }
) | ForEach-Object { Write-Host ("{0,-32} {1}" -f $_.n, $(if($_.ok){'OK'}else{'FAIL'})) }
```
Expected: 10 行全部 `OK`。
注：dot-source 会执行定义段开头的 `New-Item` —— 在本机 `D:\dev_env` 和 `__temp_cache__` 已存在，无副作用。`$Task` 脚本块只被定义不被调用，不会触发任何下载。

- [ ] **Step 7: Commit**

```powershell
git add dev_env.bat
git commit -m "feat: 菜单接入 7. apktool / 8. zipalign"
```

---

## 手动验收（由用户在提权 shell 执行）

自动化检查只覆盖语法和符号解析，真正的安装流程需手动跑。按 CLAUDE.md「Editing tips」：

1. 从**非管理员** shell 双击 / 运行 `dev_env.bat`，确认能自提权重启（UAC 弹窗）。
2. 菜单输入 `7` —— 验证：
   - `D:\dev_env\apktool\3.0.2\` 下有 `apktool_3.0.2.jar` 和 `apktool.bat`；
   - 控制台打印 `[Env] APKTOOL_HOME = ...` 和 `[Path] Added: %APKTOOL_HOME%`；
   - 打印了 JDK 提示行（若当前 `JAVA_HOME` 是 JDK 8，应提示跑 `switch_jdk.bat 17`）；
   - **新开**一个 shell，`where apktool` 能找到，`apktool --version`（JDK 11+ 下）能跑。
3. 菜单输入 `8` —— 验证：
   - `D:\dev_env\android_sdk\build-tools\35.0.0\zipalign.exe` 存在；
   - 控制台打印 `[Env] ANDROID_HOME = ...` 和 `[Path] Added: %ANDROID_HOME%\build-tools\35.0.0`；
   - **新开** shell，`where zipalign` 能找到，`zipalign` 无参运行能打印用法。
4. 回归：菜单输入 `6`，确认 `TaskAndroid` 改造后行为不变（cmdline-tools / platform-tools 正常，env 正常）。
5. 幂等性：把 `7` `8` `6` 各再跑一遍，确认走 `[Skip]` 分支且 env 仍重新应用（`[Env]`/`[Path]` 行在已安装时因值未变可能不打印，属正常）。
6. 输入 `7,8` 确认逗号分隔多选正常。

`Read-Host` 会阻塞非交互运行 —— 这些验收步骤必须人工交互执行，不能放进自动化。

---

## Self-Review

**1. Spec coverage** —— 逐条对照 `docs/superpowers/specs/2026-05-15-apktool-zipalign-design.md`：
- §1 `$v`/`$paths`/`$urls` 新增项 → Task 1 ✓
- §2 两个共享 helper → Task 2 ✓
- §3 `TaskAndroid` 改造 → Task 3 ✓
- §4 `$TaskApktool` → Task 4 ✓
- §5 `$TaskZipalign` → Task 5 ✓
- §6 菜单/`all`/`switch` → Task 6 ✓
- 错误处理与幂等性 → 各 task 的代码块已含 `throw` 与存在性校验；env 注册在 skip-return 之前 ✓
- 测试（手动）→「手动验收」一节 ✓
- 范围之外（不动 `pkg/`、不加 SHA256、不删旧扁平 jar、不改 switch 脚本）→ File Structure 的「不动」清单已声明 ✓

**2. Placeholder scan** —— 无 TBD/TODO，每个改动步骤都给了完整 old_string/new_string 代码块，验证步骤都给了具体命令和预期输出。✓

**3. Type consistency** —— 跨 task 的符号名一致：`Ensure-AndroidCmdlineTools` / `Ensure-JavaOnPath`（Task 2 定义，Task 3 调用）、`$TaskApktool`（Task 4 定义，Task 6 dispatch）、`$TaskZipalign`（Task 5 定义，Task 6 dispatch）、`$v.Apktool` / `$v.BuildTools` / `$paths.Apktool` / `$paths.BuildTools` / `$urls.ApktoolJar` / `$urls.ApktoolBat`（Task 1 定义，Task 4/5 引用）—— 全部对齐。✓
