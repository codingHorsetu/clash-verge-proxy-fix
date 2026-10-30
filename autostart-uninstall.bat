@echo off
chcp 65001 >nul
setlocal
title Disable login autostart

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\boot-agent.ps1" -Action Uninstall

echo.
echo ------------------------------------------------------------
echo   Press any key to close.
echo ------------------------------------------------------------
pause >nul
endlocal
