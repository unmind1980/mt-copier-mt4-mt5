@echo off
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "REPO=%HERE%.."
set "BIN=%REPO%\hub\target\release\copier-hub.exe"

cd /d "%REPO%"
set "PATH=%REPO%\hub\target\release;%REPO%\third_party\zmq-prefix\lib;%PATH%"

if not exist "%BIN%" (
    echo [ERROR] Cannot find copier-hub.exe at:
    echo   %BIN%
    echo Please run tools\hubrs.bat --build first.
    pause
    exit /b 1
)

rem --- Cluster token: NEVER a constant. A token that appears in this repository
rem --- is not a secret, it is a published password. Generate once here, then
rem --- copy cluster_token.txt to the standby host before starting it.
set "CP_OLD_PUBLIC_TOKEN=mtc_shared_cluster_token_2026"
set "MTC_CLUSTER_TOKEN="
if exist "cluster_token.txt" set /p MTC_CLUSTER_TOKEN=<"cluster_token.txt"
if /i "!MTC_CLUSTER_TOKEN!"=="%CP_OLD_PUBLIC_TOKEN%" set "MTC_CLUSTER_TOKEN="
if not defined MTC_CLUSTER_TOKEN (
    for /f "delims=" %%i in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString()+[guid]::NewGuid().ToString()"') do set "MTC_CLUSTER_TOKEN=%%i"
)
if not defined MTC_CLUSTER_TOKEN (
    echo [ERROR] Could not generate a cluster token ^(PowerShell unavailable^).
    echo         Create cluster_token.txt by hand with a long random string.
    pause
    exit /b 1
)
> "cluster_token.txt" echo !MTC_CLUSTER_TOKEN!
echo [cluster] Cluster token ready - random, stored in %CD%\cluster_token.txt
echo [cluster] If the standby hub runs elsewhere, copy that file there BEFORE starting it.

title mt-copier Hub - [PRIMARY (6000 / 6010)]
echo =======================================================================
echo   Starting mt-copier PRIMARY Hub (Role: Primary)
echo =======================================================================
echo   ZMQ Port      : 6000
echo   Web Dashboard : http://127.0.0.1:6010
echo   Peer ZMQ      : tcp://127.0.0.1:6001
echo   Peer API      : http://127.0.0.1:6011
echo =======================================================================
echo.

"%BIN%" --port 6000 --http 0.0.0.0:6010 --role primary --peer-api http://127.0.0.1:6011 --peer-zmq tcp://127.0.0.1:6001 %*
echo.
pause
