@echo off
setlocal EnableExtensions
title Dev Environment Installer v15
cd /d "%~dp0"

:: --- [1. Admin Check] ---
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting Admin Rights...
    goto UACPrompt
) else ( goto gotAdmin )
:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    exit /B
:gotAdmin
    if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )

:: --- [2. Extract and Run PS1] ---
set "PS_FILE=%temp%\dev_env_install.ps1"
if exist "%PS_FILE%" del /f /q "%PS_FILE%"

:: Use line number extraction to avoid regex issues
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
echo   Installation sequence finished.
echo ===================================================
pause
exit /b

:: ============================================================================
###PS_START###
$ErrorActionPreference = "Stop"
$ProgressPreference = 'Continue'
$base = "D:\dev_env"
$tempCache = Join-Path $base "__temp_cache__"

# Ensure directories
if (!(Test-Path $base)) { New-Item -ItemType Directory -Path $base | Out-Null }
if (!(Test-Path $tempCache)) { New-Item -ItemType Directory -Path $tempCache | Out-Null }

$v = @{
    Java    = "21.0.5"
    Node    = "20.18.0";   Python = "3.12.4";
    Maven   = "3.9.9";     Git    = "2.48.1";
    TGit    = "2.15.0.0";  Android = "11076708"
}

# Path Definitions: Name\Version
$paths = @{
    Java    = "$base\java\$($v.Java)"
    Node    = "$base\nodejs\$($v.Node)"
    Python  = "$base\python\$($v.Python)"
    Maven   = "$base\maven\$($v.Maven)"
    Git     = "$base\git\$($v.Git)"
    TGit    = "$base\TortoiseGit\$($v.TGit)"
    Android = "$base\android_sdk"
}

$urls = @{
    Java    = "https://download.oracle.com/java/21/archive/jdk-$($v.Java)_windows-x64_bin.zip"
    Node    = "https://nodejs.org/dist/v$($v.Node)/node-v$($v.Node)-x64.msi"
    Python  = "https://www.python.org/ftp/python/$($v.Python)/python-$($v.Python)-amd64.exe"
    Maven   = "https://archive.apache.org/dist/maven/maven-3/$($v.Maven)/binaries/apache-maven-$($v.Maven)-bin.zip"
    Git     = "https://github.com/git-for-windows/git/releases/download/v$($v.Git).windows.1/Git-$($v.Git)-64-bit.exe"
    TGit    = "https://download.tortoisegit.org/tgit/$($v.TGit)/TortoiseGit-$($v.TGit)-64bit.msi"
    TGitLang = "https://download.tortoisegit.org/tgit/$($v.TGit)/TortoiseGit-LanguagePack-$($v.TGit)-64bit-zh_CN.msi"
    Android = "https://dl.google.com/android/repository/commandlinetools-win-$($v.Android)_latest.zip"
}

# --- Helper Functions ---

function Test-CommandAvailable($cmd) {
    return $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Set-EnvVar($name, $val) {
    $current = [System.Environment]::GetEnvironmentVariable($name, "Machine")
    if ($current -ne $val) {
        [System.Environment]::SetEnvironmentVariable($name, $val, "Machine")
        try { Set-Item -Path "Env:$name" -Value $val -ErrorAction SilentlyContinue } catch {}
        Write-Host "  [Env] $name = $val" -ForegroundColor Green
    }
}

function Add-PathVar($regVal, $physPath) {
    $current = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    if (($current -split ';' -notcontains $regVal) -and ($current -split ';' -notcontains $physPath)) {
        [System.Environment]::SetEnvironmentVariable("Path", ($current.TrimEnd(';') + ";" + $regVal), "Machine")
        Write-Host "  [Path] Added: $regVal" -ForegroundColor Green
    }
    if (($env:Path -split ';' -notcontains $physPath)) { $env:Path += ";$physPath" }
}

function Download-Official($url, $file, $referer = $null) {
    $target = Join-Path $tempCache $file
    if (Test-Path $target) { return $target }

    Write-Host "  [Download] $file ..." -ForegroundColor White
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    $headers = @{}
    if ($referer) { $headers["Referer"] = $referer }

    try {
        Invoke-WebRequest -Uri $url -OutFile $target -UserAgent $ua -Headers $headers -MaximumRedirection 10
    } catch {
        Write-Host "  [Retry via curl.exe] $($_.Exception.Message)" -ForegroundColor Yellow
        $curlArgs = @("-L", "--fail", "--retry", "3", "-A", $ua, "-o", $target, $url)
        if ($referer) { $curlArgs = @("-e", $referer) + $curlArgs }
        & curl.exe @curlArgs
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
    }
    return $target
}

# --- Task Functions ---

$TaskJava = {
    Write-Host "`n>> Oracle JDK $($v.Java)" -ForegroundColor Cyan
    if (Test-CommandAvailable "java") { Write-Host "  [Skip] Java already in system." -ForegroundColor Yellow; return }

    if (!(Test-Path $paths.Java)) {
        $f = Download-Official $urls.Java "jdk.zip"
        Expand-Archive $f -DestinationPath "$tempCache\jdk" -Force
        $inner = Get-ChildItem "$tempCache\jdk" -Directory | Select-Object -First 1
        New-Item -ItemType Directory -Path (Split-Path $paths.Java) -Force | Out-Null
        Move-Item $inner.FullName $paths.Java -Force
    }
    Set-EnvVar "JAVA_HOME" $paths.Java
    Add-PathVar "%JAVA_HOME%\bin" "$($paths.Java)\bin"
}

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
        if (Test-Path "$($paths.Java)\bin\java.exe") {
            $env:Path = "$($paths.Java)\bin;$env:Path"
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

# --- Execution ---

Clear-Host
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "      Smart Dev Environment Installer" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " 1. Java | 2. Node | 3. Python | 4. Maven | 5. Git | 6. Android | all. All"
$choice = Read-Host "`nChoice"
if ($choice -eq "") { exit }

$selected = if ($choice -eq "all") { @("1","2","3","4","5","6") } else { $choice -split "," }

try {
    foreach ($item in $selected) {
        $idx = $selected.IndexOf($item) + 1
        Write-Progress -Activity "Installation Progress" -Status "Working on Task $idx" -PercentComplete ([int]($idx/$selected.Count*100))
        $key = "$item".Trim()
        switch ($key) {
            "1" { & $TaskJava }
            "2" { & $TaskNode }
            "3" { & $TaskPython }
            "4" { & $TaskMaven }
            "5" { & $TaskGit }
            "6" { & $TaskAndroid }
        }
    }
    
    # Refresh Environment Variable Broadcaster
    $win32Code = @"
    using System;
    using System.Runtime.InteropServices;
    public class Win32Helper {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    }
"@
    try {
        if (-not ([System.Management.Automation.PSTypeName]'Win32Helper').Type) {
            Add-Type -TypeDefinition $win32Code
        }
        $res = [UIntPtr]::Zero
        [Win32Helper]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$res) | Out-Null
        Write-Host "`n[SUCCESS] Environment variables broadcasted." -ForegroundColor Green
    } catch {
        Write-Host "`n[INFO] Environment updated. Please restart terminal." -ForegroundColor Yellow
    }
} catch {
    Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if (Test-Path $tempCache) { Remove-Item $tempCache -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Progress -Activity "Installation Progress" -Completed
}
###PS_END###