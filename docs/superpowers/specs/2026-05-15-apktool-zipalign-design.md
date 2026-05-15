# 设计稿：dev_env.bat 新增 apktool 与 zipalign

日期：2026-05-15
状态：已批准设计，待写实施计划

## 目标

在 `dev_env.bat` 中新增两个工具安装任务，使 `apktool` 和 `zipalign` 命令安装到 `D:\dev_env` 下并注册到 Machine 作用域 PATH：

- **apktool** —— Android APK 反编译工具，jar + 包装脚本形式。
- **zipalign** —— Android SDK build-tools 的一部分，APK 字节对齐工具。

两者各占一个新菜单编号（`7`、`8`），遵循 repo 既有的 per-tool `$Task` 脚本块模式。

## 背景与约束

- `dev_env.bat` 是 bat 包 PowerShell 的 polyglot 文件，PS 载荷在 `###PS_START###`/`###PS_END###` 之间。标记行必须保持列 0、字面不变。
- 每个工具是一个 `$TaskXxx = { ... }` 脚本块，由菜单 `switch` 派发。标准形态：skip-if-present → `Download-Official` 下载到 `$tempCache` → 安装 → 注册 env。
- `apktool` 官方分发：GitHub releases 的 `apktool_<ver>.jar` + 仓库里的 `apktool.bat` 包装脚本。包装脚本在自身所在目录查找 `apktool.jar` 或 `apktool_X.Y.Z.jar`（取版本号最高者）。apktool 3.x 需要 Java 11+，而本 repo 默认 `JAVA_HOME` 指向 JDK 8。
- `zipalign` 没有官方独立下载，只随 Android SDK `build-tools` 分发，通过 `sdkmanager "build-tools;<ver>"` 安装。`sdkmanager` 需要 cmdline-tools 和 PATH 上的 Java。
- 环境变量末尾通过 `SendMessageTimeout` 广播，新变量自动生效，无需重启终端。

## 已确认的设计决策

1. **菜单结构**：两个独立编号 `7. apktool` 和 `8. zipalign`，各自一个 `$Task` 脚本块。
2. **zipalign 依赖处理**：自包含 —— 缺 cmdline-tools 就自己下载装。为此把 `TaskAndroid` 里下载 cmdline-tools 的逻辑抽成共享 helper，`TaskAndroid` 和 `TaskZipalign` 都调用。
3. **apktool 版本**：钉 `3.0.2`（最新稳定版，与用户磁盘上现有 jar 一致）；任务里打印 JDK 版本提示。

## 详细设计

### 1. `$v` / `$paths` / `$urls` 新增项

`$v` 哈希表新增：

```
Apktool    = "3.0.2"
BuildTools = "35.0.0"
```

`BuildTools` 选 `35.0.0`：稳定且用户磁盘上已有该版本，skip 逻辑可直接命中。

`$paths` 哈希表新增：

```
Apktool    = "$base\apktool\$($v.Apktool)"                       # D:\dev_env\apktool\3.0.2
BuildTools = "$base\android_sdk\build-tools\$($v.BuildTools)"     # D:\dev_env\android_sdk\build-tools\35.0.0
```

`Apktool` 用版本化子目录，符合 CLAUDE.md「版本化目录作为幂等性检查」的约定。磁盘上现存的扁平 `D:\dev_env\apktool\apktool.jar` 不删除（与 repo「旧版本不清理」一致），新版装进版本化子目录。

`$urls` 哈希表新增：

```
ApktoolJar = "https://github.com/iBotPeaches/Apktool/releases/download/v$($v.Apktool)/apktool_$($v.Apktool).jar"
ApktoolBat = "https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/windows/apktool.bat"
```

`zipalign` 复用现有的 `$urls.Android`（cmdline-tools 下载地址），无需新 URL。

### 2. 共享 helper 函数（重构）

在 helper 函数区（`Merge-SplitFiles` 之后、`# --- Task Functions ---` 之前）新增两个函数：

**`Ensure-AndroidCmdlineTools`** —— 确保 `$paths.Android\cmdline-tools\latest` 存在，返回 `sdkmanager.bat` 路径。**不检查 Java**。逻辑取自现 `TaskAndroid` 的下载块：

```powershell
function Ensure-AndroidCmdlineTools {
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
```

**`Ensure-JavaOnPath`** —— 若 `java` 不在 PATH，把 `$paths.Java8\bin` 或 `$paths.Java17\bin` 前置到当前进程 `$env:Path`；两者都没有则 `throw`。逻辑取自现 `TaskAndroid`：

```powershell
function Ensure-JavaOnPath {
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
```

**拆成两个函数的理由**：保留原有行为。Java 检查只应在「真要跑 sdkmanager」时发生；当 adb / zipalign 已存在而走 skip 分支时，不应因缺 Java 报错。原 `TaskAndroid` 正是把 Java 检查放在 adb skip 检查之后。

### 3. `TaskAndroid` 改造

用 helper 替换内联逻辑，行为不变（仅去重）：

```powershell
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

注意：env 注册仍在 adb skip 检查之前（保持近期 commit 修的「早退不漏注册」模式）。

### 4. `$TaskApktool`（菜单 7）

```powershell
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
```

- skip 判据：版本化目录下的 `apktool_3.0.2.jar` 是否存在。
- 下载 jar 和 `apktool.bat` 包装脚本，放进版本化目录。包装脚本会自动在同目录找 `apktool_*.jar`。
- `APKTOOL_HOME` 指向版本化目录，PATH 加 `%APKTOOL_HOME%`，使 `apktool` 命令可解析。
- env 注册在 skip 分支之外，无论是否 skip 都重新应用（自愈）。

### 5. `$TaskZipalign`（菜单 8）

```powershell
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
```

- 自包含：`Ensure-AndroidCmdlineTools` 缺 cmdline-tools 就自己装，不要求先跑选项 6。
- 注册 `ANDROID_HOME`，PATH 加整个 `%ANDROID_HOME%\build-tools\35.0.0` 目录（顺带带上 `apksigner`、`aapt` 等）。
- skip 判据：`build-tools\35.0.0\zipalign.exe` 是否存在；存在则 return（env 已在前面注册）。
- 否则 `Ensure-JavaOnPath` → `sdkmanager --licenses` → `sdkmanager "build-tools;35.0.0"`。

### 6. 菜单与 dispatch

- 菜单文案（现第 445 行）末尾加 `| 7. apktool | 8. zipalign`：

  ```
  Write-Host " 1. Java(8+17) | 2. Node | 3. Python | 4. Maven | 5. Git | 6. Android | 7. apktool | 8. zipalign | all. All"
  ```

- `all` 分支（现第 449 行）扩展为 `@("1","2","3","4","5","6","7","8")`。
- `switch`（现第 456–463 行）新增：

  ```
  "7" { & $TaskApktool }
  "8" { & $TaskZipalign }
  ```

## 错误处理与幂等性

- 两个新 task 都在 skip-return 之前注册 env 变量，重跑可自愈（与近期 commit 修的早退 bug 模式一致）。
- 下载走现有 `Download-Official`（Chrome UA + curl 回退）。GitHub release 资源的重定向由 `-MaximumRedirection 10` 处理。
- 安装后都有存在性校验 + `throw`。
- `Ensure-AndroidCmdlineTools` 和 `Ensure-JavaOnPath` 各自带 `throw`，失败信息明确。
- 末尾的环境变量广播不变，新变量（`APKTOOL_HOME`、`ANDROID_HOME` 及新 PATH 项）自动生效。

## 测试（手动）

无测试套件，按 CLAUDE.md「Editing tips」手动验证：

1. 从非管理员 shell 跑 `dev_env.bat`，确认能自提权重启。
2. 选 `7` —— 验证 `D:\dev_env\apktool\3.0.2\` 下有 `apktool_3.0.2.jar` 和 `apktool.bat`，`APKTOOL_HOME` 已设，PATH 含 `%APKTOOL_HOME%`。新开 shell 后 `apktool` 可解析。
3. 选 `8` —— 验证 `build-tools\35.0.0\zipalign.exe` 存在，PATH 含 build-tools 目录。新开 shell 后 `zipalign` 可解析。
4. 选 `7,8` 和 `6`（回归）—— 确认 `TaskAndroid` 改造后行为不变。
5. 重跑确认 skip 分支正常，且 env 仍重新应用。

注意：`Read-Host` 会阻塞非交互运行，菜单流不要加新的输入提示。

## 范围之外

- 不动 `pkg/` 离线缓存。
- 不为 apktool 加 SHA256 校验（JDK 那套分包校验是因为走第三方镜像；apktool 走 GitHub 官方 release）。
- 不删除磁盘上现存的扁平 `D:\dev_env\apktool\apktool.jar`。
- 不改 `switch_jdk.bat` / `switch_python.bat`，也不为 apktool 加版本切换脚本。
