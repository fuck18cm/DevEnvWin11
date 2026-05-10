@echo off
setlocal EnableExtensions
title JDK Version Switcher
cd /d "%~dp0"

:: --- [1. Admin Check] ---
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting Admin Rights...
    goto UACPrompt
) else ( goto gotAdmin )
:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin_jdk.vbs"
    echo UAC.ShellExecute "%~s0", "%*", "", "runas", 1 >> "%temp%\getadmin_jdk.vbs"
    "%temp%\getadmin_jdk.vbs"
    exit /B
:gotAdmin
    if exist "%temp%\getadmin_jdk.vbs" ( del "%temp%\getadmin_jdk.vbs" )

:: --- [2. Resolve target version] ---
set "VER=%~1"
if "%VER%"=="" (
    echo Available JDK versions: 8, 17
    set /p VER=Choose JDK version:
)

set "TARGET="
if /I "%VER%"=="8"  set "TARGET=D:\dev_env\java\jdk-8"
if /I "%VER%"=="17" set "TARGET=D:\dev_env\java\jdk-17"

if not defined TARGET (
    echo [ERROR] Invalid version: "%VER%". Use 8 or 17.
    pause & exit /b 1
)

if not exist "%TARGET%\bin\java.exe" (
    echo [ERROR] JDK not installed at %TARGET%
    echo Run dev_env.bat (option 1) to install JDKs first.
    pause & exit /b 1
)

set "TARGET_JDK=%TARGET%"

:: --- [3. Extract embedded PS and run it] ---
set "PS_FILE=%temp%\switch_jdk.ps1"
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
echo   JAVA_HOME switched to: %TARGET%
echo   Open a NEW terminal and run: java -version
echo ===================================================
pause
exit /b

:: ============================================================================
###PS_START###
$ErrorActionPreference = "Stop"
$target = $env:TARGET_JDK
if (-not $target) { Write-Host "[ERROR] TARGET_JDK not provided." -ForegroundColor Red; exit 1 }

[System.Environment]::SetEnvironmentVariable("JAVA_HOME", $target, "Machine")
$env:JAVA_HOME = $target
Write-Host "[Env] JAVA_HOME = $target" -ForegroundColor Green

# Broadcast WM_SETTINGCHANGE so already-open Explorer/shells refresh
$win32Code = @"
using System;
using System.Runtime.InteropServices;
public class Win32HelperJdk {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
"@
try {
    if (-not ([System.Management.Automation.PSTypeName]'Win32HelperJdk').Type) {
        Add-Type -TypeDefinition $win32Code
    }
    $res = [UIntPtr]::Zero
    [Win32HelperJdk]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$res) | Out-Null
    Write-Host "[OK] Environment broadcasted." -ForegroundColor Green
} catch {
    Write-Host "[INFO] Set saved. Restart terminal to apply." -ForegroundColor Yellow
}
###PS_END###
