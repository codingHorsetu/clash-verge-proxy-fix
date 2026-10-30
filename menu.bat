@echo off
chcp 65001 >nul
setlocal
title Proxy Residue Fix - Menu

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
set "SCRIPT=%~dp0src\proxy-residue-fix.ps1"
set "BOOT=%~dp0src\boot-agent.ps1"

:menu
cls
echo ============================================================
echo   Proxy Residue Fix
echo ============================================================
echo    1  Diagnose only (read-only)
echo    2  Repair (clear residual proxy settings)
echo    3  Switch to direct connection
echo    4  Restart proxy client
echo    5  Stop proxy client safely
echo    ----------------------------------------------
echo    6  Enable login autostart   (optional)
echo    7  Disable login autostart
echo    8  Autostart status
echo    0  Exit
echo ============================================================
choice /c 123456780 /n /m "Select: "

rem choice returns 1..9 for 1,2,3,4,5,6,7,8,0 in that order
if errorlevel 9 goto end
if errorlevel 8 ( "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -Action Status & goto after )
if errorlevel 7 ( "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -Action Uninstall & goto after )
if errorlevel 6 ( "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -Action Install & goto after )
if errorlevel 5 set "ACT=Stop"
if errorlevel 4 set "ACT=Restart"
if errorlevel 3 set "ACT=Direct"
if errorlevel 2 set "ACT=Fix"
if errorlevel 1 set "ACT=Check"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action %ACT%

:after
echo.
echo ------------------------------------------------------------
pause
goto menu

:end
endlocal
