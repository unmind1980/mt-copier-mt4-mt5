@echo off
setlocal
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

if exist "cluster_token.txt" (
    set /p MTC_CLUSTER_TOKEN=<"cluster_token.txt"
) else (
    set "MTC_CLUSTER_TOKEN=mtc_shared_cluster_token_2026"
    echo mtc_shared_cluster_token_2026> "cluster_token.txt"
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
