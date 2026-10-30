@echo off
rem =============================================================
rem  Run a single command with a local proxy, WITHOUT touching
rem  the system-wide environment variables.
rem
rem  Usage:
rem      with-proxy.bat claude
rem      with-proxy.bat git clone https://github.com/user/repo
rem      set PROXY_PORT=7890 & with-proxy.bat npm install
rem
rem  This is the safe alternative to setting HTTP_PROXY globally.
rem  A global variable keeps working after the proxy is gone and
rem  breaks every app that reads it.
rem =============================================================
setlocal

if "%PROXY_PORT%"=="" set "PROXY_PORT=7897"

set "HTTP_PROXY=http://127.0.0.1:%PROXY_PORT%"
set "HTTPS_PROXY=http://127.0.0.1:%PROXY_PORT%"
set "ALL_PROXY=http://127.0.0.1:%PROXY_PORT%"
set "NO_PROXY=localhost,127.0.0.1,::1"

if "%~1"=="" (
    echo Usage: with-proxy ^<command^> [args...]
    echo Example: with-proxy claude
    echo Proxy: http://127.0.0.1:%PROXY_PORT%
    exit /b 1
)

%*
exit /b %ERRORLEVEL%
