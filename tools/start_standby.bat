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

if not exist "standby_data" mkdir "standby_data"
if not exist "standby_data\curve_clients.txt" (
    if exist "curve_clients.txt" (
        copy "curve_clients.txt" "standby_data\curve_clients.txt" >nul
    ) else (
        echo * > "standby_data\curve_clients.txt"
    )
)

rem --- The standby MUST NOT invent its own token. A hub pair that disagrees on
rem --- the token silently fails every peer probe (401), reports "disconnected"
rem --- forever, and never fails over. Take the file from the primary.
set "CP_OLD_PUBLIC_TOKEN=mtc_shared_cluster_token_2026"
set "MTC_CLUSTER_TOKEN="
if exist "cluster_token.txt" set /p MTC_CLUSTER_TOKEN=<"cluster_token.txt"
if /i "!MTC_CLUSTER_TOKEN!"=="%CP_OLD_PUBLIC_TOKEN%" set "MTC_CLUSTER_TOKEN="
if not defined MTC_CLUSTER_TOKEN (
    echo [ERROR] No usable cluster token found.
    echo         1^) Start the PRIMARY hub first - it generates cluster_token.txt.
    echo         2^) Copy that file next to this script.
    echo         Without a shared token the hubs cannot authenticate and
    echo         failover will never work.
    pause
    exit /b 1
)

title mt-copier Hub - [STANDBY (6001 / 6011)]
echo =======================================================================
echo   Starting mt-copier STANDBY Hub (Role: Standby)
echo =======================================================================
echo   ZMQ Port      : 6001
echo   Web Dashboard : http://127.0.0.1:6011
echo   Peer ZMQ      : tcp://127.0.0.1:6000
echo   Peer API      : http://127.0.0.1:6010
echo   Data Folder   : %REPO%\standby_data\
echo =======================================================================
echo.

"%BIN%" --port 6001 --http 0.0.0.0:6011 --role standby --peer-api http://127.0.0.1:6010 --peer-zmq tcp://127.0.0.1:6000 --cluster-state standby_data\cluster_state.json --config standby_data\config_revisions.jsonl --commands standby_data\commands.jsonl --users standby_data\users.json --notifications standby_data\alert_channels.json --curve-clients standby_data\curve_clients.txt --curve-keys curve_hub.keys --audit standby_data\audit.jsonl %*
echo.
pause
