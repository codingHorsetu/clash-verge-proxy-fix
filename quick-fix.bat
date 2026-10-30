@echo off
chcp 65001 >nul
setlocal
title Proxy Residue Fix - One Click

rem  One-click repair: run a read-only check, then apply the fix, then pause.
rem  Nothing is installed and nothing stays running in the background.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

set "SCRIPT=%~dp0src\proxy-residue-fix.ps1"

echo ============================================================
echo   Step 1/2  Diagnose
echo ============================================================
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Check

echo.
echo ============================================================
echo   Step 2/2  Repair
echo ============================================================
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Fix -Force

echo.
echo ------------------------------------------------------------
echo   Done. Press any key to close.
echo ------------------------------------------------------------
pause >nul
endlocal
