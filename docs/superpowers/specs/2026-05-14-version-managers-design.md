# Version Manager Refactor & Early-Return Bugfix

**Date**: 2026-05-14
**Status**: Design — awaiting user review
**Scope file**: `dev_env.bat` (PowerShell payload), new `switch_python.bat`

## 1. Background

`dev_env.bat` is a single-file Windows installer that drops toolchains under `D:\dev_env\<tool>\<version>` and registers Machine-scope env vars. Two problems motivate this spec:

1. **Node has no version-switching story.** Today the script installs one fixed Node version (`$v.Node = "20.18.0"`) via MSI to `D:\dev_env\nodejs\<ver>` and points PATH at it. Bumping `$v.Node` creates a sibling install but leaves the user no clean way to flip between versions.
2. **All non-Java task blocks share an early-return bug.** Each tool task starts with `if (Test-CommandAvailable "<bin>") { ...return }`. If the binary exists *anywhere* on PATH (prior install, manual install, partially-completed earlier run), the entire task body is skipped — including the `Set-EnvVar` / `Add-PathVar` calls. The user noticed this through Python: `python` was on PATH but `%PYTHON_HOME%\Scripts` was missing, with no way for re-running the script to self-heal.

This spec addresses both in one pass and adds Python version switching for symmetry with the existing `switch_jdk.bat`.

## 2. Scope

In scope:
- Replace `$TaskNode` with an nvm-windows–driven flow; install default Node `v18.18.0` through nvm
- Fix the early-return pattern in `$TaskPython`, `$TaskMaven`, and `$TaskGit` (Node is rewritten so the bug goes away naturally)
- Add `switch_python.bat`, structurally identical to `switch_jdk.bat`

Out of scope:
- TortoiseGit changes (no early-return there; works correctly)
- Java tasks (already fine — JDK 8/17 split-install + `switch_jdk.bat`)
- Android task (no early-return; idempotency keyed on filesystem)
- Deleting old `D:\dev_env\nodejs\20.18.0` / `D:\dev_env\python\<old>` directories left behind by previous runs — they get renamed if they conflict, otherwise left alone

## 3. Design — Node via nvm-windows

### 3.1 Variables & paths

```powershell
$v.Nvm  = "1.1.12"
$v.Node = "18.18.0"

$paths.Nvm     = "$base\nvm"      # NVM_HOME — nvm.exe lives here
$paths.NodeSym = "$base\nodejs"   # NVM_SYMLINK — active version's bin dir

$urls.Nvm = "https://github.com/coreybutler/nvm-windows/releases/download/$($v.Nvm)/nvm-setup.zip"
```

The old `$paths.Node = "$base\nodejs\$($v.Node)"` is removed.

### 3.2 New `$TaskNode` flow

1. **Pre-flight conflict check.** If `D:\dev_env\nodejs` already exists as a regular directory (left over from the pre-nvm install layout) and is not already a symlink/junction, rename it to `D:\dev_env\nodejs.bak`. If `nodejs.bak` already exists, append a timestamp suffix (`nodejs.bak.20260514-153012`) so the rename never destroys a previous backup. Print a one-line notice. Detect symlink/junction via `(Get-Item $paths.NodeSym).LinkType` — only `$null` (plain dir) gets renamed.

2. **Skip-install gate.** If `Test-Path "$($paths.Nvm)\nvm.exe"` → skip download/install; fall through to env-var alignment and the default-version-install step. Otherwise:
   - `Download-Official $urls.Nvm "nvm-setup.zip"` → `Expand-Archive` to `$tempCache\nvm-setup-extract` → run `nvm-setup.exe /SILENT /SUPPRESSMSGBOXES /DIR="$($paths.Nvm)"` with `-Wait`.
   - After return, verify `Test-Path "$($paths.Nvm)\nvm.exe"`; throw a clear error if missing (likely means the installer rejected `/DIR=` and we need to switch to nvm-noinstall.zip — see §6 risks).

3. **Override `settings.txt`.** The installer writes its own `settings.txt` (root + symlink path) based on installer-page defaults. Overwrite it unconditionally:
   ```
   root: D:\dev_env\nvm
   path: D:\dev_env\nodejs
   ```
   Use `Set-Content -Encoding ASCII` (nvm-windows reads this as plain text).

4. **Env vars (Machine scope + current session).**
   - `NVM_HOME = $paths.Nvm`
   - `NVM_SYMLINK = $paths.NodeSym`
   - Remove the old `NODE_HOME` Machine var if present (no longer meaningful).

5. **PATH cleanup + add.**
   - Strip any existing `C:\Program Files\nodejs` entry from Machine PATH (installer's default symlink location that we're overriding).
   - Strip any literal `D:\dev_env\nodejs\<ver>` entry left over from the old MSI-based install.
   - Strip any `%NODE_HOME%` entry left over from the old install.
   - `Add-PathVar` `%NVM_HOME%` and `%NVM_SYMLINK%`.

6. **Install default Node version.** `nvm.exe` reads `NVM_HOME` and `NVM_SYMLINK` from the current process; the `Set-EnvVar` calls in step 4 hydrate both `$env:NVM_HOME` and `$env:NVM_SYMLINK` for the running PS session, so the following two commands resolve correctly.
   - `& "$($paths.Nvm)\nvm.exe" install $($v.Node)` (idempotent — nvm reports "already installed" if so)
   - `& "$($paths.Nvm)\nvm.exe" use $($v.Node)` — this creates the symlink at `$paths.NodeSym`. Requires admin, which we already have.
   - Sanity check: `Test-Path "$($paths.NodeSym)\node.exe"`; throw if missing.

### 3.3 New helper: `Remove-PathEntry`

`Add-PathVar` currently has no removal counterpart. Add:

```powershell
function Remove-PathEntry($pattern) {
    # $pattern may be a literal entry or a wildcard
    $current = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $entries = $current -split ';' | Where-Object { $_ -and ($_ -notlike $pattern) }
    $new = ($entries -join ';')
    if ($new -ne $current) {
        [System.Environment]::SetEnvironmentVariable("Path", $new, "Machine")
        Write-Host "  [Path] Removed entries matching: $pattern" -ForegroundColor Yellow
    }
    $env:Path = ($env:Path -split ';' | Where-Object { $_ -and ($_ -notlike $pattern) }) -join ';'
}
```

Used by §3.2 step 5.

## 4. Design — Python early-return fix + multi-version switching

### 4.1 `$TaskPython` rewrite

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

    # Env vars + PATH always re-applied, regardless of install state
    Set-EnvVar "PYTHON_HOME" $paths.Python
    Add-PathVar "%PYTHON_HOME%" $paths.Python
    Add-PathVar "%PYTHON_HOME%\Scripts" "$($paths.Python)\Scripts"
}
```

Key changes:
- Skip gate moved from `Test-CommandAvailable "python"` → `Test-Path "$($paths.Python)\python.exe"`. We only manage what we installed; pre-existing `python` elsewhere on PATH is irrelevant to our env-var bookkeeping.
- Env-var lines unconditionally executed every run, so re-running the script can self-heal missing PATH entries.
- Download filename includes version (`python-$($v.Python).exe`) so cache isn't poisoned across version bumps.
- Added post-install assertion.

### 4.2 `switch_python.bat`

Clone `switch_jdk.bat` with these substitutions:
- Title: `Python Version Switcher`
- VBS temp filename: `getadmin_python.vbs`
- PS temp filename: `switch_python.ps1`
- Env var being set: `PYTHON_HOME` (not `JAVA_HOME`)
- Win32 helper class name: `Win32HelperPython`
- Target resolution: enumerate `D:\dev_env\python\*` subdirs that contain `python.exe`; let the user pick by version arg (e.g., `switch_python.bat 3.12.4`) or interactively when no arg given
- Validation: target dir must contain `python.exe`

Because PATH was registered symbolically as `%PYTHON_HOME%` and `%PYTHON_HOME%\Scripts`, switching just `PYTHON_HOME` updates *both* effective paths automatically. No PATH rewrite needed in the switcher.

### 4.3 Multi-version coexistence

`$paths.Python = "$base\python\$($v.Python)"` already encodes the version. Bumping `$v.Python` creates a new versioned dir alongside the old one. After the bump, on first run:
- The new dir doesn't exist → install proceeds
- `PYTHON_HOME` is updated to the new path
- Old dir is untouched on disk

User can `switch_python.bat <old-version>` to flip back at any time.

## 5. Design — Maven & Git early-return fixes

### 5.1 `$TaskMaven`

```powershell
$TaskMaven = {
    Write-Host "`n>> Maven" -ForegroundColor Cyan

    if (!(Test-Path "$($paths.Maven)\bin\mvn.cmd")) {
        $f = Download-Official $urls.Maven "mvn-$($v.Maven).zip"
        Expand-Archive $f -DestinationPath "$tempCache\mvn" -Force
        $inner = Get-ChildItem "$tempCache\mvn" -Directory | Select-Object -First 1
        New-Item -ItemType Directory -Path (Split-Path $paths.Maven) -Force | Out-Null
        Move-Item $inner.FullName $paths.Maven -Force
    } else {
        Write-Host "  [Skip] Maven $($v.Maven) already at $($paths.Maven)" -ForegroundColor Yellow
    }

    Set-EnvVar "M2_HOME" $paths.Maven
    Set-EnvVar "MAVEN_OPTS" "-Xms256m -Xmx512m -Dfile.encoding=UTF-8"
    Add-PathVar "%M2_HOME%\bin" "$($paths.Maven)\bin"
}
```

Same shape as Python: filesystem-based skip gate, env-var lines unconditional.

### 5.2 `$TaskGit`

Two sub-blocks: Git and TortoiseGit. Only the Git half has the bug; TortoiseGit is fine.

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

    # TortoiseGit block unchanged (already idempotent on filesystem)
    if (!(Test-Path $paths.TGit)) {
        $f = Download-Official $urls.TGit "tgit.msi" "https://tortoisegit.org/download/"
        Start-Process msiexec.exe -ArgumentList "/i `"$f`" /quiet /norestart INSTALLDIR=`"$($paths.TGit)`"" -Wait
    }
    Add-PathVar "$($paths.TGit)\bin" "$($paths.TGit)\bin"

    if (Test-Path $paths.TGit) {
        $langMarker = "$($paths.TGit)\Languages\TortoiseProc2052.dll"
        if (Test-Path $langMarker) {
            Write-Host "  [Lang] zh_CN already installed." -ForegroundColor Yellow
        } else {
            Write-Host "  [Lang] Installing TortoiseGit zh_CN language pack..." -ForegroundColor White
            $f = Download-Official $urls.TGitLang "tgit_lang_zh_CN.msi" "https://tortoisegit.org/download/"
            Start-Process msiexec.exe -ArgumentList "/i `"$f`" /quiet /norestart" -Wait
        }
    }
}
```

Notes:
- PATH entry stays at `$($paths.Git)\bin` to match the current installed state — avoids leaving a stale `\bin` entry in PATH alongside a new `\cmd` one (since `Add-PathVar` doesn't remove the old).
- Git's PATH entry remains the resolved literal path (not symbolic via `GIT_HOME`), matching today's behavior. We could symbolize it for future version-switching parity, but you didn't ask for Git version switching and adding `GIT_HOME` is unnecessary churn.
- Download cache filename includes version, same reasoning as Python/Maven.

## 6. Risks & open questions

1. **nvm-setup.exe silent flags.** I'm confident about `/SILENT` and `/SUPPRESSMSGBOXES` (standard Inno Setup), reasonably confident `/DIR=` works against nvm-windows 1.1.12. If `/DIR=` is silently ignored, the installer drops to a default path and our `Test-Path "$($paths.Nvm)\nvm.exe"` assertion fails immediately — error message will say "switch to nvm-noinstall.zip". Acceptable failure mode; user can rerun after manual cleanup.

2. **Installer creates its own `NVM_HOME` / `NVM_SYMLINK`.** Silent install of nvm-windows registers these env vars itself, pointing at its chosen locations. Our code re-writes them in step 5 after the installer finishes. Sequence-dependent — must use `-Wait` on `Start-Process`.

3. **Old `C:\Program Files\nodejs` symlink left by installer.** We strip the PATH entry but don't delete the directory itself (may be a valid junction nvm-windows created, may be empty). Leaving it on disk is harmless once PATH is fixed.

4. **`Remove-PathEntry` wildcard semantics.** Using PowerShell `-notlike` (case-insensitive, supports `*`/`?`). Risk: an overly broad pattern strips legitimate entries. Spec uses literal entries except for the `D:\dev_env\nodejs\*` cleanup which uses a wildcard. Worth reviewing the exact patterns when implementing.

5. **Idempotency of `nvm install`/`nvm use`.** Both are idempotent on success; `nvm install` reports "Version 18.18.0 is already installed" and returns nonzero in some edge cases. Implementation will not treat nonzero from `nvm install` as fatal if the target version dir already exists under `$paths.Nvm\v$($v.Node)`.

## 7. Out-of-band cleanup the user may want to do later

These are explicitly **not** automated by this change:
- Delete `D:\dev_env\nodejs.bak` (if created) once you've confirmed nothing relies on the old install
- Delete `D:\dev_env\python\<old-version>` directories after switching away from them
- Delete `C:\Program Files\nodejs` if it was left behind by nvm-windows installer
