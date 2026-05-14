# Version Managers & Early-Return Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `$TaskNode` in `dev_env.bat` to install Node via nvm-windows (default `v18.18.0`), fix the early-return bug in `$TaskPython`/`$TaskMaven`/`$TaskGit`, and add `switch_python.bat` for version switching.

**Architecture:** All changes are inside the PowerShell payload of `dev_env.bat` (between `###PS_START###` and `###PS_END###` markers). One new file at repo root: `switch_python.bat`. No tests — `dev_env.bat` is a one-shot Windows installer requiring admin; verification uses PowerShell `Parser::ParseInput` syntax checks plus targeted `grep` to confirm patterns before/after each edit. Final smoke test is manual.

**Tech Stack:** Windows batch (cmd.exe), PowerShell 5.x, nvm-windows 1.1.12.

**Spec reference:** `docs/superpowers/specs/2026-05-14-version-managers-design.md`

---

## File Structure

**Modified:**
- `dev_env.bat` — single-file installer. Edits in five regions:
  - `$v` hashtable (lines 54-59): add `Nvm`, change `Node` default to `18.18.0`
  - `$paths` hashtable (lines 62-71): replace `Node` with `Nvm` + `NodeSym`
  - `$urls` hashtable (lines 73-82): replace `Node` MSI URL with `Nvm` zip URL
  - Helpers (after line 106): add `Remove-PathEntry` function
  - `$TaskNode` (lines 208-218): full rewrite
  - `$TaskPython` (lines 220-231): early-return fix
  - `$TaskMaven` (lines 233-247): early-return fix
  - `$TaskGit` (lines 249-276): early-return fix on Git half only (TortoiseGit untouched)

**Created:**
- `switch_python.bat` (repo root) — clone of `switch_jdk.bat` structure, sets `PYTHON_HOME`

---

## Conventions for this plan

1. **Verification commands assume PWD = repo root (`D:\dev_env\DevEnvWin11`).**
2. **All commands use PowerShell** since the dev environment is Windows. Sandbox-friendly: parse-only checks, no execution of `dev_env.bat`.
3. **The PS-payload syntax check** is reused across tasks. Helper command:
   ```powershell
   powershell -NoProfile -Command "$txt = Get-Content -Raw dev_env.bat; $s = $txt.IndexOf('###PS_START###') + '###PS_START###'.Length; $e = $txt.IndexOf('###PS_END###'); $ps = $txt.Substring($s, $e - $s); $errs = $null; [System.Management.Automation.Language.Parser]::ParseInput($ps, [ref]$null, [ref]$errs) | Out-Null; if ($errs) { $errs | Format-List; exit 1 } else { 'OK' }"
   ```
   Expected output: `OK` (with exit 0).
4. **Commits use Conventional Commits in Chinese** to match existing repo style (`改用`, `修改` etc.). Each task ends with one focused commit.
5. **Bracketed line ranges (`L62-71`)** in edit instructions refer to lines in the **current** file at the start of that task. Line numbers shift after each edit; use the surrounding context strings to anchor, not the numbers.

---

## Task 1: Add `Remove-PathEntry` helper

**Files:**
- Modify: `dev_env.bat` (insert after the `Add-PathVar` function, currently ending around L106)

- [ ] **Step 1: Read the helper region for context**

Run:
```powershell
powershell -NoProfile -Command "Get-Content dev_env.bat | Select-Object -Skip 98 -First 12"
```
Expected: prints lines containing `function Add-PathVar` through the closing `}`. Note the exact `Add-PathVar` closing brace as the anchor for insertion.

- [ ] **Step 2: Insert `Remove-PathEntry` directly below `Add-PathVar`**

Use Edit tool. Locate this exact block (the entire `Add-PathVar` function plus the blank line after it):

```powershell
function Add-PathVar($regVal, $physPath) {
    $current = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    if (($current -split ';' -notcontains $regVal) -and ($current -split ';' -notcontains $physPath)) {
        [System.Environment]::SetEnvironmentVariable("Path", ($current.TrimEnd(';') + ";" + $regVal), "Machine")
        Write-Host "  [Path] Added: $regVal" -ForegroundColor Green
    }
    if (($env:Path -split ';' -notcontains $physPath)) { $env:Path += ";$physPath" }
}

function Download-Official($url, $file, $referer = $null) {
```

Replace with:

```powershell
function Add-PathVar($regVal, $physPath) {
    $current = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    if (($current -split ';' -notcontains $regVal) -and ($current -split ';' -notcontains $physPath)) {
        [System.Environment]::SetEnvironmentVariable("Path", ($current.TrimEnd(';') + ";" + $regVal), "Machine")
        Write-Host "  [Path] Added: $regVal" -ForegroundColor Green
    }
    if (($env:Path -split ';' -notcontains $physPath)) { $env:Path += ";$physPath" }
}

function Remove-PathEntry($pattern) {
    $current = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $kept = $current -split ';' | Where-Object { $_ -and ($_ -notlike $pattern) }
    $new = ($kept -join ';')
    if ($new -ne $current) {
        [System.Environment]::SetEnvironmentVariable("Path", $new, "Machine")
        Write-Host "  [Path] Removed entries matching: $pattern" -ForegroundColor Yellow
    }
    $env:Path = (($env:Path -split ';' | Where-Object { $_ -and ($_ -notlike $pattern) }) -join ';')
}

function Download-Official($url, $file, $referer = $null) {
```

- [ ] **Step 3: Verify the function is present and PS payload still parses**

Run:
```powershell
powershell -NoProfile -Command "(Select-String -Path dev_env.bat -Pattern 'function Remove-PathEntry').Count"
```
Expected: `1`

Run the PS-payload syntax check from the Conventions section.
Expected: `OK`

- [ ] **Step 4: Commit**

```powershell
git add dev_env.bat
git commit -m "添加 Remove-PathEntry 辅助函数"
```

---

## Task 2: Update `$v`, `$paths`, `$urls` for nvm-driven Node

**Files:**
- Modify: `dev_env.bat` (three hashtables, currently L54-82)

- [ ] **Step 1: Read the current hashtables**

Run:
```powershell
powershell -NoProfile -Command "Get-Content dev_env.bat | Select-Object -Skip 53 -First 30"
```
Expected: shows `$v`, `$paths`, `$urls` blocks.

- [ ] **Step 2: Update `$v` — add `Nvm`, switch default `Node`**

Edit tool. Find:

```powershell
$v = @{
    Java8   = "8";          Java17 = "17"
    Node    = "20.18.0";    Python = "3.12.4";
    Maven   = "3.9.9";      Git    = "2.48.1";
    TGit    = "2.15.0.0";   Android = "11076708"
}
```

Replace with:

```powershell
$v = @{
    Java8   = "8";          Java17  = "17"
    Nvm     = "1.1.12";     Node    = "18.18.0"
    Python  = "3.12.4";     Maven   = "3.9.9"
    Git     = "2.48.1";     TGit    = "2.15.0.0"
    Android = "11076708"
}
```

- [ ] **Step 3: Update `$paths` — replace `Node` with `Nvm` + `NodeSym`**

Edit tool. Find:

```powershell
# Path Definitions: Name\Version
$paths = @{
    Java8   = "$base\java\jdk-8"
    Java17  = "$base\java\jdk-17"
    Node    = "$base\nodejs\$($v.Node)"
    Python  = "$base\python\$($v.Python)"
    Maven   = "$base\maven\$($v.Maven)"
    Git     = "$base\git\$($v.Git)"
    TGit    = "$base\TortoiseGit\$($v.TGit)"
    Android = "$base\android_sdk"
}
```

Replace with:

```powershell
# Path Definitions: Name\Version
$paths = @{
    Java8   = "$base\java\jdk-8"
    Java17  = "$base\java\jdk-17"
    Nvm     = "$base\nvm"
    NodeSym = "$base\nodejs"
    Python  = "$base\python\$($v.Python)"
    Maven   = "$base\maven\$($v.Maven)"
    Git     = "$base\git\$($v.Git)"
    TGit    = "$base\TortoiseGit\$($v.TGit)"
    Android = "$base\android_sdk"
}
```

- [ ] **Step 4: Update `$urls` — replace `Node` MSI URL with `Nvm` zip URL**

Edit tool. Find:

```powershell
    Node    = "https://nodejs.org/dist/v$($v.Node)/node-v$($v.Node)-x64.msi"
```

Replace with:

```powershell
    Nvm     = "https://github.com/coreybutler/nvm-windows/releases/download/$($v.Nvm)/nvm-setup.zip"
```

- [ ] **Step 5: Verify**

Run:
```powershell
powershell -NoProfile -Command "Select-String -Path dev_env.bat -Pattern 'Nvm\s*=\s*\"1\.1\.12\"','NodeSym\s*=','nvm-setup\.zip' | ForEach-Object { $_.LineNumber.ToString() + ': ' + $_.Line.Trim() }"
```
Expected: three matched lines, one for each pattern.

Run PS-payload syntax check from Conventions.
Expected: `OK`

- [ ] **Step 6: Confirm old `Node` MSI URL is gone**

Run:
```powershell
powershell -NoProfile -Command "(Select-String -Path dev_env.bat -Pattern 'node-v.*-x64\.msi').Count"
```
Expected: `0`

- [ ] **Step 7: Commit**

```powershell
git add dev_env.bat
git commit -m "更新变量定义：引入 NVM_HOME/NVM_SYMLINK，Node 默认版改为 18.18.0"
```

---

## Task 3: Rewrite `$TaskNode` using nvm-windows

**Files:**
- Modify: `dev_env.bat` (`$TaskNode` block, currently L208-218)

- [ ] **Step 1: Read the current `$TaskNode`**

Run:
```powershell
powershell -NoProfile -Command "Get-Content dev_env.bat | Select-Object -Skip 207 -First 12"
```
Expected: prints `$TaskNode = { ... }` block.

- [ ] **Step 2: Replace the entire block**

Edit tool. Find:

```powershell
$TaskNode = {
    Write-Host "`n>> Node.js" -ForegroundColor Cyan
    if (Test-CommandAvailable "node") { Write-Host "  [Skip] Node already in system." -ForegroundColor Yellow; return }
    
    if (!(Test-Path $paths.Node)) {
        $f = Download-Official $urls.Node "node.msi"
        Start-Process msiexec.exe -ArgumentList "/i `"$f`" /quiet /norestart INSTALLDIR=`"$($paths.Node)`"" -Wait
    }
    Set-EnvVar "NODE_HOME" $paths.Node
    Add-PathVar "%NODE_HOME%" $paths.Node
}
```

Replace with:

```powershell
$TaskNode = {
    Write-Host "`n>> Node.js (via nvm-windows)" -ForegroundColor Cyan

    # Pre-flight: if D:\dev_env\nodejs is a regular dir (old layout), back it up
    if (Test-Path $paths.NodeSym) {
        $item = Get-Item $paths.NodeSym -Force
        if ($null -eq $item.LinkType) {
            $bak = "$($paths.NodeSym).bak"
            if (Test-Path $bak) {
                $bak = "$bak.$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
            }
            Write-Host "  [Backup] $($paths.NodeSym) -> $bak (old layout detected)" -ForegroundColor Yellow
            Move-Item $paths.NodeSym $bak -Force
        }
    }

    # Install nvm-windows if not already there
    if (!(Test-Path "$($paths.Nvm)\nvm.exe")) {
        $zip = Download-Official $urls.Nvm "nvm-setup-$($v.Nvm).zip"
        $extractDir = Join-Path $tempCache "nvm-setup-extract"
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive $zip -DestinationPath $extractDir -Force
        $setupExe = Join-Path $extractDir "nvm-setup.exe"
        if (!(Test-Path $setupExe)) { throw "nvm-setup.exe not found after extracting $zip" }

        Write-Host "  [Install] nvm-windows $($v.Nvm) -> $($paths.Nvm)" -ForegroundColor White
        Start-Process $setupExe -ArgumentList "/SILENT","/SUPPRESSMSGBOXES","/DIR=`"$($paths.Nvm)`"" -Wait

        if (!(Test-Path "$($paths.Nvm)\nvm.exe")) {
            throw "nvm install failed: $($paths.Nvm)\nvm.exe not found. The /DIR= flag may not be honored; switch to nvm-noinstall.zip."
        }
    } else {
        Write-Host "  [Skip] nvm-windows already at $($paths.Nvm)" -ForegroundColor Yellow
    }

    # Force settings.txt to our chosen paths (overrides whatever installer wrote)
    $settingsPath = Join-Path $paths.Nvm "settings.txt"
    $settingsContent = "root: $($paths.Nvm)`r`npath: $($paths.NodeSym)`r`n"
    Set-Content -Path $settingsPath -Value $settingsContent -Encoding ASCII
    Write-Host "  [Config] $settingsPath updated" -ForegroundColor Green

    # Remove env vars / PATH entries from the old MSI-based layout
    if ([System.Environment]::GetEnvironmentVariable("NODE_HOME", "Machine")) {
        [System.Environment]::SetEnvironmentVariable("NODE_HOME", $null, "Machine")
        Write-Host "  [Env] Removed legacy NODE_HOME" -ForegroundColor Yellow
    }
    Remove-PathEntry "%NODE_HOME%"
    Remove-PathEntry "$base\nodejs\*"
    Remove-PathEntry "C:\Program Files\nodejs"

    # Register new env vars (Machine + current session)
    Set-EnvVar "NVM_HOME"    $paths.Nvm
    Set-EnvVar "NVM_SYMLINK" $paths.NodeSym
    Add-PathVar "%NVM_HOME%"    $paths.Nvm
    Add-PathVar "%NVM_SYMLINK%" $paths.NodeSym

    # Install default Node version via nvm
    $nvm = "$($paths.Nvm)\nvm.exe"
    Write-Host "  [Node] nvm install $($v.Node)" -ForegroundColor White
    & $nvm install $($v.Node) | Out-Host
    Write-Host "  [Node] nvm use $($v.Node)" -ForegroundColor White
    & $nvm use $($v.Node) | Out-Host

    if (!(Test-Path "$($paths.NodeSym)\node.exe")) {
        throw "Node activation failed: $($paths.NodeSym)\node.exe not found after 'nvm use'."
    }
    Write-Host "  [OK] Node $($v.Node) active at $($paths.NodeSym)" -ForegroundColor Green
}
```

- [ ] **Step 3: Verify the new block is present and parses**

Run:
```powershell
powershell -NoProfile -Command "(Select-String -Path dev_env.bat -Pattern 'nvm-windows','NVM_SYMLINK','Remove-PathEntry').Count"
```
Expected: ≥ 5 (mention of nvm-windows in comment + Write-Host, NVM_SYMLINK in 2 places, Remove-PathEntry called 3 times)

Run:
```powershell
powershell -NoProfile -Command "(Select-String -Path dev_env.bat -Pattern 'Test-CommandAvailable \"node\"').Count"
```
Expected: `0` (the early-return is gone)

Run PS-payload syntax check from Conventions.
Expected: `OK`

- [ ] **Step 4: Commit**

```powershell
git add dev_env.bat
git commit -m "TaskNode 改用 nvm-windows 管理 Node 版本"
```

---

## Task 4: Fix `$TaskPython` early-return

**Files:**
- Modify: `dev_env.bat` (`$TaskPython` block, currently around L220-231)

- [ ] **Step 1: Read the current `$TaskPython`**

Run:
```powershell
powershell -NoProfile -Command "Get-Content dev_env.bat | Select-String -Pattern '\$TaskPython = \{' -Context 0,15"
```
Expected: prints the block.

- [ ] **Step 2: Replace the block**

Edit tool. Find:

```powershell
$TaskPython = {
    Write-Host "`n>> Python" -ForegroundColor Cyan
    if (Test-CommandAvailable "python") { Write-Host "  [Skip] Python already in system." -ForegroundColor Yellow; return }

    if (!(Test-Path $paths.Python)) {
        $f = Download-Official $urls.Python "python.exe"
        Start-Process $f -ArgumentList "/quiet InstallAllUsers=1 PrependPath=0 TargetDir=`"$($paths.Python)`"" -Wait
    }
    Set-EnvVar "PYTHON_HOME" $paths.Python
    Add-PathVar "%PYTHON_HOME%" $paths.Python
    Add-PathVar "%PYTHON_HOME%\Scripts" "$($paths.Python)\Scripts"
}
```

Replace with:

```powershell
$TaskPython = {
    Write-Host "`n>> Python" -ForegroundColor Cyan

    if (!(Test-Path "$($paths.Python)\python.exe")) {
        $f = Download-Official $urls.Python "python-$($v.Python).exe"
        Start-Process $f -ArgumentList "/quiet InstallAllUsers=1 PrependPath=0 TargetDir=`"$($paths.Python)`"" -Wait
        if (!(Test-Path "$($paths.Python)\python.exe")) { throw "Python install failed at $($paths.Python)" }
    } else {
        Write-Host "  [Skip] Python $($v.Python) already at $($paths.Python)" -ForegroundColor Yellow
    }

    # Env vars + PATH re-applied every run so a partial previous install can self-heal
    Set-EnvVar "PYTHON_HOME" $paths.Python
    Add-PathVar "%PYTHON_HOME%" $paths.Python
    Add-PathVar "%PYTHON_HOME%\Scripts" "$($paths.Python)\Scripts"
}
```

- [ ] **Step 3: Verify**

Run:
```powershell
powershell -NoProfile -Command "(Select-String -Path dev_env.bat -Pattern 'Test-CommandAvailable \"python\"').Count"
```
Expected: `0`

Run:
```powershell
powershell -NoProfile -Command "(Select-String -Path dev_env.bat -Pattern '%PYTHON_HOME%\\\\Scripts').Count"
```
Expected: `1`

Run PS-payload syntax check from Conventions.
Expected: `OK`

- [ ] **Step 4: Commit**

```powershell
git add dev_env.bat
git commit -m "修复 TaskPython 早退导致 Scripts 路径不重应用的 bug"
```

---

## Task 5: Fix `$TaskMaven` early-return

**Files:**
- Modify: `dev_env.bat` (`$TaskMaven` block, currently around L233-247)

- [ ] **Step 1: Read the current `$TaskMaven`**

Run:
```powershell
powershell -NoProfile -Command "Get-Content dev_env.bat | Select-String -Pattern '\$TaskMaven = \{' -Context 0,15"
```
Expected: prints the block.

- [ ] **Step 2: Replace the block**

Edit tool. Find:

```powershell
$TaskMaven = {
    Write-Host "`n>> Maven" -ForegroundColor Cyan
    if (Test-CommandAvailable "mvn") { Write-Host "  [Skip] Maven already in system." -ForegroundColor Yellow; return }

    if (!(Test-Path $paths.Maven)) {
        $f = Download-Official $urls.Maven "mvn.zip"
        Expand-Archive $f -DestinationPath "$tempCache\mvn" -Force
        $inner = Get-ChildItem "$tempCache\mvn" -Directory | Select-Object -First 1
        New-Item -ItemType Directory -Path (Split-Path $paths.Maven) -Force | Out-Null
        Move-Item $inner.FullName $paths.Maven -Force
    }
    Set-EnvVar "M2_HOME" $paths.Maven
    Set-EnvVar "MAVEN_OPTS" "-Xms256m -Xmx512m -Dfile.encoding=UTF-8"
    Add-PathVar "%M2_HOME%\bin" "$($paths.Maven)\bin"
}
```

Replace with:

```powershell
$TaskMaven = {
    Write-Host "`n>> Maven" -ForegroundColor Cyan

    if (!(Test-Path "$($paths.Maven)\bin\mvn.cmd")) {
        $f = Download-Official $urls.Maven "mvn-$($v.Maven).zip"
        Expand-Archive $f -DestinationPath "$tempCache\mvn" -Force
        $inner = Get-ChildItem "$tempCache\mvn" -Directory | Select-Object -First 1
        New-Item -ItemType Directory -Path (Split-Path $paths.Maven) -Force | Out-Null
        Move-Item $inner.FullName $paths.Maven -Force
        if (!(Test-Path "$($paths.Maven)\bin\mvn.cmd")) { throw "Maven install failed at $($paths.Maven)" }
    } else {
        Write-Host "  [Skip] Maven $($v.Maven) already at $($paths.Maven)" -ForegroundColor Yellow
    }

    Set-EnvVar "M2_HOME" $paths.Maven
    Set-EnvVar "MAVEN_OPTS" "-Xms256m -Xmx512m -Dfile.encoding=UTF-8"
    Add-PathVar "%M2_HOME%\bin" "$($paths.Maven)\bin"
}
```

- [ ] **Step 3: Verify**

Run:
```powershell
powershell -NoProfile -Command "(Select-String -Path dev_env.bat -Pattern 'Test-CommandAvailable \"mvn\"').Count"
```
Expected: `0`

Run PS-payload syntax check from Conventions.
Expected: `OK`

- [ ] **Step 4: Commit**

```powershell
git add dev_env.bat
git commit -m "修复 TaskMaven 早退导致环境变量不重应用的 bug"
```

---

## Task 6: Fix `$TaskGit` early-return (Git half only)

**Files:**
- Modify: `dev_env.bat` (Git portion of `$TaskGit`, currently around L249-258; TortoiseGit portion untouched)

- [ ] **Step 1: Read the current `$TaskGit` head**

Run:
```powershell
powershell -NoProfile -Command "Get-Content dev_env.bat | Select-String -Pattern '\$TaskGit = \{' -Context 0,10"
```
Expected: prints the Git half plus a few lines into TortoiseGit.

- [ ] **Step 2: Replace ONLY the Git half**

Edit tool. Find:

```powershell
$TaskGit = {
    Write-Host "`n>> Git & TortoiseGit" -ForegroundColor Cyan
    if (Test-CommandAvailable "git") { Write-Host "  [Skip] Git already works." -ForegroundColor Yellow }
    else {
        if (!(Test-Path $paths.Git)) {
            $f = Download-Official $urls.Git "git.exe"
            Start-Process $f -ArgumentList "/VERYSILENT /NORESTART /DIR=`"$($paths.Git)`"" -Wait
        }
        Add-PathVar "$($paths.Git)\bin" "$($paths.Git)\bin"
    }
```

Replace with:

```powershell
$TaskGit = {
    Write-Host "`n>> Git & TortoiseGit" -ForegroundColor Cyan

    if (!(Test-Path "$($paths.Git)\bin\git.exe")) {
        $f = Download-Official $urls.Git "git-$($v.Git).exe"
        Start-Process $f -ArgumentList "/VERYSILENT /NORESTART /DIR=`"$($paths.Git)`"" -Wait
        if (!(Test-Path "$($paths.Git)\bin\git.exe")) { throw "Git install failed at $($paths.Git)" }
    } else {
        Write-Host "  [Skip] Git $($v.Git) already at $($paths.Git)" -ForegroundColor Yellow
    }
    Add-PathVar "$($paths.Git)\bin" "$($paths.Git)\bin"
```

(Note: do NOT touch the TortoiseGit portion that follows — leave `if (!(Test-Path $paths.TGit)) { ... }` and the language-pack block alone.)

- [ ] **Step 3: Verify**

Run:
```powershell
powershell -NoProfile -Command "(Select-String -Path dev_env.bat -Pattern 'Test-CommandAvailable \"git\"').Count"
```
Expected: `0`

Run:
```powershell
powershell -NoProfile -Command "(Select-String -Path dev_env.bat -Pattern 'TortoiseProc2052\.dll').Count"
```
Expected: `1` (confirms TortoiseGit language-pack check is still intact)

Run PS-payload syntax check from Conventions.
Expected: `OK`

- [ ] **Step 4: Sanity check — no remaining `Test-CommandAvailable` early-returns in the targeted tasks**

Run:
```powershell
powershell -NoProfile -Command "Select-String -Path dev_env.bat -Pattern 'Test-CommandAvailable' | ForEach-Object { $_.LineNumber.ToString() + ': ' + $_.Line.Trim() }"
```
Expected: only the `function Test-CommandAvailable` definition line should appear. No call-sites for `node`, `python`, `mvn`, or `git`.

- [ ] **Step 5: Commit**

```powershell
git add dev_env.bat
git commit -m "修复 TaskGit 早退导致 PATH 不重应用的 bug"
```

---

## Task 7: Create `switch_python.bat`

**Files:**
- Create: `switch_python.bat` (repo root)

- [ ] **Step 1: Confirm reference file exists**

Run:
```powershell
powershell -NoProfile -Command "Test-Path switch_jdk.bat"
```
Expected: `True`

- [ ] **Step 2: Write the new file**

Use Write tool to create `switch_python.bat` with this exact content:

```bat
@echo off
setlocal EnableExtensions
title Python Version Switcher
cd /d "%~dp0"

:: --- [1. Admin Check] ---
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting Admin Rights...
    goto UACPrompt
) else ( goto gotAdmin )
:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin_python.vbs"
    echo UAC.ShellExecute "%~s0", "%*", "", "runas", 1 >> "%temp%\getadmin_python.vbs"
    "%temp%\getadmin_python.vbs"
    exit /B
:gotAdmin
    if exist "%temp%\getadmin_python.vbs" ( del "%temp%\getadmin_python.vbs" )

:: --- [2. Resolve target version] ---
set "VER=%~1"
set "PYROOT=D:\dev_env\python"

if "%VER%"=="" (
    echo Available Python versions under %PYROOT%:
    for /d %%D in ("%PYROOT%\*") do (
        if exist "%%D\python.exe" echo   - %%~nxD
    )
    set /p VER=Choose Python version:
)

set "TARGET=%PYROOT%\%VER%"
if not exist "%TARGET%\python.exe" (
    echo [ERROR] Python not installed at %TARGET%
    echo Run dev_env.bat ^(option 3^) to install, or pick another version.
    pause & exit /b 1
)

set "TARGET_PYTHON=%TARGET%"

:: --- [3. Extract embedded PS and run it] ---
set "PS_FILE=%temp%\switch_python.ps1"
if exist "%PS_FILE%" del /f /q "%PS_FILE%"

set /a startLine=0
set /a endLine=0
for /f "tokens=1 delims=:" %%i in ('findstr /n /b /c:"###PS_START###" "%~f0"') do set /a startLine=%%i
for /f "tokens=1 delims=:" %%i in ('findstr /n /b /c:"###PS_END###" "%~f0"') do set /a endLine=%%i
set /a count=%endLine%-%startLine%-1

powershell -NoProfile -Command "Get-Content '%~f0' | Select-Object -Skip %startLine% | Select-Object -First %count% | Out-File -FilePath '%PS_FILE%' -Encoding UTF8"
powershell -ExecutionPolicy Bypass -File "%PS_FILE%"
if exist "%PS_FILE%" del "%PS_FILE%"

echo.
echo ===================================================
echo   PYTHON_HOME switched to: %TARGET%
echo   Open a NEW terminal and run: python --version
echo ===================================================
pause
exit /b

:: ============================================================================
###PS_START###
$ErrorActionPreference = "Stop"
$target = $env:TARGET_PYTHON
if (-not $target) { Write-Host "[ERROR] TARGET_PYTHON not provided." -ForegroundColor Red; exit 1 }

[System.Environment]::SetEnvironmentVariable("PYTHON_HOME", $target, "Machine")
$env:PYTHON_HOME = $target
Write-Host "[Env] PYTHON_HOME = $target" -ForegroundColor Green

# Broadcast WM_SETTINGCHANGE so already-open Explorer/shells refresh
$win32Code = @"
using System;
using System.Runtime.InteropServices;
public class Win32HelperPython {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
"@
try {
    if (-not ([System.Management.Automation.PSTypeName]'Win32HelperPython').Type) {
        Add-Type -TypeDefinition $win32Code
    }
    $res = [UIntPtr]::Zero
    [Win32HelperPython]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$res) | Out-Null
    Write-Host "[OK] Environment broadcasted." -ForegroundColor Green
} catch {
    Write-Host "[INFO] Set saved. Restart terminal to apply." -ForegroundColor Yellow
}
###PS_END###
```

- [ ] **Step 3: Verify the PS payload inside the new file parses**

Run:
```powershell
powershell -NoProfile -Command "$txt = Get-Content -Raw switch_python.bat; $s = $txt.IndexOf('###PS_START###') + '###PS_START###'.Length; $e = $txt.IndexOf('###PS_END###'); $ps = $txt.Substring($s, $e - $s); $errs = $null; [System.Management.Automation.Language.Parser]::ParseInput($ps, [ref]$null, [ref]$errs) | Out-Null; if ($errs) { $errs | Format-List; exit 1 } else { 'OK' }"
```
Expected: `OK`

- [ ] **Step 4: Confirm structural parity with `switch_jdk.bat`**

Run:
```powershell
powershell -NoProfile -Command "$a = (Select-String -Path switch_jdk.bat -Pattern '###PS_START###|###PS_END###|SendMessageTimeout').Count; $b = (Select-String -Path switch_python.bat -Pattern '###PS_START###|###PS_END###|SendMessageTimeout').Count; if ($a -eq $b) { 'OK' } else { 'mismatch: jdk=' + $a + ' python=' + $b; exit 1 }"
```
Expected: `OK`

- [ ] **Step 5: Commit**

```powershell
git add switch_python.bat
git commit -m "新增 switch_python.bat，对齐 switch_jdk.bat 的版本切换模式"
```

---

## Task 8: Final integrated verification

**Files:** read-only checks.

- [ ] **Step 1: Full PS-payload syntax check on `dev_env.bat`**

Run the PS-payload syntax check from the Conventions section.
Expected: `OK`

- [ ] **Step 2: Confirm all early-return calls are gone from target tasks**

Run:
```powershell
powershell -NoProfile -Command "$hits = Select-String -Path dev_env.bat -Pattern 'Test-CommandAvailable\s+\"(node|python|mvn|git)\"'; if ($hits) { $hits | Format-List; exit 1 } else { 'OK — no early-return call-sites for node/python/mvn/git' }"
```
Expected: `OK — no early-return call-sites for node/python/mvn/git`

- [ ] **Step 3: Confirm `Remove-PathEntry` is defined and used**

Run:
```powershell
powershell -NoProfile -Command "$def = (Select-String -Path dev_env.bat -Pattern '^function Remove-PathEntry').Count; $calls = (Select-String -Path dev_env.bat -Pattern '    Remove-PathEntry ').Count; if ($def -eq 1 -and $calls -ge 3) { 'OK — def=1, calls=' + $calls } else { 'FAIL — def=' + $def + ' calls=' + $calls; exit 1 }"
```
Expected: `OK — def=1, calls=3` (or more)

- [ ] **Step 4: Confirm hashtables are coherent**

Run:
```powershell
powershell -NoProfile -Command "$keys = @('Nvm','Node','NodeSym','Python','Maven','Git'); foreach ($k in $keys) { $matches = (Select-String -Path dev_env.bat -Pattern ('\$paths\.' + $k + '\b|\$v\.' + $k + '\b|\$urls\.' + $k + '\b')).Count; Write-Host ('  ' + $k + ': ' + $matches + ' references') }"
```
Expected: each key listed has ≥1 reference. (Hard numbers vary; just sanity-check none are 0.)

- [ ] **Step 5: Confirm switch_python.bat exists at repo root**

Run:
```powershell
powershell -NoProfile -Command "Test-Path switch_python.bat"
```
Expected: `True`

- [ ] **Step 6: Git status sanity**

Run:
```powershell
git status
```
Expected: working tree clean.

Run:
```powershell
git log --oneline -10
```
Expected: the 7 task commits at the top, in order:
1. `添加 Remove-PathEntry 辅助函数`
2. `更新变量定义：引入 NVM_HOME/NVM_SYMLINK，Node 默认版改为 18.18.0`
3. `TaskNode 改用 nvm-windows 管理 Node 版本`
4. `修复 TaskPython 早退导致 Scripts 路径不重应用的 bug`
5. `修复 TaskMaven 早退导致环境变量不重应用的 bug`
6. `修复 TaskGit 早退导致 PATH 不重应用的 bug`
7. `新增 switch_python.bat，对齐 switch_jdk.bat 的版本切换模式`

- [ ] **Step 7: Manual smoke test instructions for the user**

This is **not automatable** in this session (requires admin elevation, writes to system PATH, downloads ~80MB). Hand off to the user with this exact instruction:

> **Manual smoke test required.** Open File Explorer, double-click `dev_env.bat`. Approve the UAC prompt. At the prompt, type `2` (Node). The script should:
> 1. Download `nvm-setup-1.1.12.zip` to `D:\dev_env\__temp_cache__\`
> 2. Run the installer silently
> 3. Print `[Config] D:\dev_env\nvm\settings.txt updated`
> 4. Print `[Path] Added: %NVM_HOME%` and `[Path] Added: %NVM_SYMLINK%`
> 5. Run `nvm install 18.18.0` then `nvm use 18.18.0`
> 6. Print `[OK] Node 18.18.0 active at D:\dev_env\nodejs`
>
> Open a **new** cmd (not the script's prompt) and run:
> ```cmd
> nvm version
> node --version
> ```
> Expected: `1.1.12` and `v18.18.0`.
>
> Then run `dev_env.bat` again, choose `3` (Python). It should print `[Skip] Python 3.12.4 already at D:\dev_env\python\3.12.4` (assuming it was previously installed) AND register PYTHON_HOME + both PATH entries (you'll see `[Path] Added: %PYTHON_HOME%\Scripts` if it was missing before).
>
> Finally, test `switch_python.bat 3.12.4`. It should set `PYTHON_HOME=D:\dev_env\python\3.12.4` and broadcast WM_SETTINGCHANGE.
>
> If anything fails, capture the console output and report back — common failure mode is `/DIR=` being ignored by nvm-setup (then `nvm.exe` won't be at the expected path and the script throws with a clear message).

- [ ] **Step 8: No commit needed for this task** — it's verification only.

---

## Self-Review Notes

**Spec coverage check:** All spec sections accounted for:
- §3.1 variables/paths → Task 2 ✓
- §3.2 TaskNode flow (steps 1-6) → Task 3 ✓
- §3.3 Remove-PathEntry helper → Task 1 ✓
- §4.1 TaskPython rewrite → Task 4 ✓
- §4.2 switch_python.bat → Task 7 ✓
- §4.3 multi-version coexistence → emerges naturally from §4.1 (no extra task needed; `$paths.Python` versioned)
- §5.1 TaskMaven fix → Task 5 ✓
- §5.2 TaskGit fix → Task 6 ✓

**Placeholder check:** No TBDs. Every step has either exact code or exact commands with expected output.

**Type/name consistency:** `$paths.NodeSym`, `NVM_SYMLINK`, `Remove-PathEntry`, `Win32HelperPython` — used consistently across tasks.

**Out-of-band cleanup** from spec §7 is intentionally not in the plan — the spec explicitly lists those as user-driven actions, not automated steps.
