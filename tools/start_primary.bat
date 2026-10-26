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
