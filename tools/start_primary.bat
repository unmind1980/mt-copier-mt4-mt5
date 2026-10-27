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
rem --- is not a secret, it is a published password. It is minted ONCE and then
rem --- reused on every later start; there is no automatic rotation.
rem --- To rotate by hand: stop both hubs, delete cluster_token.txt, start the
rem --- primary (it mints a new one), copy the file to the standby, start it.
set "CP_OLD_PUBLIC_TOKEN=mtc_shared_cluster_token_2026"
set "CP_TOKEN_FRESH=0"
set "MTC_CLUSTER_TOKEN="
if exist "cluster_token.txt" set /p MTC_CLUSTER_TOKEN=<"cluster_token.txt"
if /i "!MTC_CLUSTER_TOKEN!"=="%CP_OLD_PUBLIC_TOKEN%" set "MTC_CLUSTER_TOKEN="
if not defined MTC_CLUSTER_TOKEN (
    for /f "delims=" %%i in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString()+[guid]::NewGuid().ToString()"') do (
        set "MTC_CLUSTER_TOKEN=%%i"
        set "CP_TOKEN_FRESH=1"
    )
)
if not defined MTC_CLUSTER_TOKEN (
    echo [ERROR] Could not generate a cluster token ^(PowerShell unavailable^).
    echo         Create cluster_token.txt by hand with a long random string.
    pause
    exit /b 1
)
rem --- Only write the file when it was actually minted. Rewriting an unchanged
rem --- token on every start is pointless, and a standby reading the file at that
rem --- moment can see it truncated. "If it is not broken, do not touch it."
if "!CP_TOKEN_FRESH!"=="1" (
    > "cluster_token.txt" echo !MTC_CLUSTER_TOKEN!
    echo [cluster] Minted a NEW random cluster token -> %CD%\cluster_token.txt
    echo [cluster] Copy that file to the standby host BEFORE starting it there.
) else (
    echo [cluster] Using the existing cluster token from %CD%\cluster_token.txt
)

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
