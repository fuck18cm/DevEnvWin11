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
