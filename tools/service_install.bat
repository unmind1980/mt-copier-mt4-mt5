@echo off
setlocal enabledelayedexpansion

echo =======================================================================
echo   MT-Copier - Install Windows Service (Interactive Selector)
echo =======================================================================
echo.

rem --- Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Administrator privileges are required to install Windows Services.
    echo.
    echo   Please right-click this batch file and choose:
    echo   "Run as administrator"
    echo.
    pause
    exit /b 1
)

set "HERE=%~dp0"
set "REPO=%HERE%.."
cd /d "%REPO%"

set "BIN=%REPO%\hub\target\release\copier-hub.exe"
if not exist "%BIN%" (
    echo [ERROR] Cannot find copier-hub.exe at:
    echo   %BIN%
    echo Please run tools\deploy.sh / build.sh --release first.
    pause
    exit /b 1
)

rem --- H4: optional instance suffix, so a second Primary/Standby can live on this
rem --- host without reconfiguring the first one. Unset = historic service names.
rem --- Delayed expansion (!VAR!) is mandatory here: cmd.exe expands %VAR% for a
rem --- whole if(...) block before running it, so a value set inside the block is
rem --- invisible to a %VAR% reference in the same block - which silently made
rem --- --instance a no-op and made a second install reconfigure the first service.
set "MTC_INST_ARG="
set "MTC_INST_SUFFIX="
if defined MTC_INSTANCE (
    set "MTC_INST_ARG=--instance !MTC_INSTANCE!"
    set "MTC_INST_SUFFIX=_!MTC_INSTANCE!"
)

rem --- Ensure cluster token exists
if not exist "cluster_token.txt" (
    for /f "delims=" %%i in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString()+[guid]::NewGuid().ToString()"') do (
        > "cluster_token.txt" echo %%i
        echo [cluster] Generated new cluster token: %%i
    )
)

echo Please choose which Windows Service to install on THIS computer:
echo.
echo   [1] Production Primary VPS  (Only Primary Hub: Port 6000 ZMQ / 6010 HTTP / 443 HTTPS)
echo   [2] Production Standby VPS  (Only Standby Hub: Port 6001 ZMQ / 6011 HTTP)
echo   [3] Local Dev/Test Machine  (Both Primary + Standby Hubs on this single machine)
echo   [0] Cancel
echo.
set /p CHOICE="Enter choice [1, 2, 3 or 0]: "

if "%CHOICE%"=="1" goto :install_primary
if "%CHOICE%"=="2" goto :install_standby
if "%CHOICE%"=="3" goto :install_both
echo Cancelled.
exit /b 0

:install_primary
echo.
echo =======================================================================
echo   [Optional] Configure Peer Standby VPS:
echo   If your architecture includes a Standby VPS, enter its IP (e.g. 168.100.200.50).
echo   If running standalone without a standby, press Enter to skip (default):
echo =======================================================================
set "PEER_IP="
set /p PEER_IP="Peer Standby IP (Enter to leave blank for Standalone): "

echo.
echo [1/2] Installing MTCopierPrimary service...
if "!PEER_IP!"=="" (
    echo [Mode] Standalone Mode (No peer standby configured)
    "%BIN%" --service-install primary !MTC_INST_ARG! --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role primary
) else (
    echo [Mode] HA Cluster Mode (Peer standby: !PEER_IP!)
    "%BIN%" --service-install primary !MTC_INST_ARG! --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role primary --peer-api http://!PEER_IP!:6010 --peer-zmq tcp://!PEER_IP!:6000
)
if %errorLevel% neq 0 (
    echo [ERROR] Failed to install MTCopierPrimary service.
    pause
    exit /b 1
)
echo [2/2] Starting MTCopierPrimary service...
sc start MTCopierPrimary!MTC_INST_SUFFIX! >nul 2>&1
timeout /t 2 /nobreak >nul
goto :verify

:install_standby
echo.
if not exist "standby_data" mkdir "standby_data"
echo =======================================================================
echo   [Configure Peer Primary VPS]:
echo   Enter the IP address of the Primary VPS (e.g. 149.135.109.18).
echo   Or press Enter to skip and configure later in Web UI:
echo =======================================================================
set "PEER_IP="
set /p PEER_IP="Peer Primary IP (Enter to skip): "

echo.
echo [1/2] Installing MTCopierStandby service...
if "!PEER_IP!"=="" (
    echo [Mode] Standby Initializing (Configure Primary in Web UI later)
    "%BIN%" --service-install standby !MTC_INST_ARG! --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role standby --cluster-state standby_data\cluster_state.json --config standby_data\config_revisions.jsonl --commands standby_data\commands.jsonl --users standby_data\users.json --notifications standby_data\alert_channels.json --curve-clients standby_data\curve_clients.txt --curve-keys curve_hub.keys --audit standby_data\audit.jsonl
) else (
    echo [Mode] Standby Mirror Mode (Peer primary: !PEER_IP!)
    "%BIN%" --service-install standby !MTC_INST_ARG! --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role standby --peer-api http://!PEER_IP!:6010 --peer-zmq tcp://!PEER_IP!:6000 --cluster-state standby_data\cluster_state.json --config standby_data\config_revisions.jsonl --commands standby_data\commands.jsonl --users standby_data\users.json --notifications standby_data\alert_channels.json --curve-clients standby_data\curve_clients.txt --curve-keys curve_hub.keys --audit standby_data\audit.jsonl
)
if %errorLevel% neq 0 (
    echo [ERROR] Failed to install MTCopierStandby service.
    pause
    exit /b 1
)
echo [2/2] Starting MTCopierStandby service...
sc start MTCopierStandby!MTC_INST_SUFFIX! >nul 2>&1
timeout /t 2 /nobreak >nul
goto :verify

:install_both
echo.
if not exist "standby_data" mkdir "standby_data"
echo [Local Dual HA Dev/Test] Installing Primary (6000/6010) and Standby (6001/6011)...
"%BIN%" --service-install primary !MTC_INST_ARG! --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role primary --peer-api http://127.0.0.1:6011 --peer-zmq tcp://127.0.0.1:6001
"%BIN%" --service-install standby !MTC_INST_ARG! --workdir "%REPO%" --port 6001 --http 0.0.0.0:6011 --role standby --peer-api http://127.0.0.1:6010 --peer-zmq tcp://127.0.0.1:6000 --cluster-state standby_data\cluster_state.json --config standby_data\config_revisions.jsonl --commands standby_data\commands.jsonl --users standby_data\users.json --notifications standby_data\alert_channels.json --curve-clients standby_data\curve_clients.txt --curve-keys curve_hub.keys --audit standby_data\audit.jsonl
echo Starting services...
sc start MTCopierPrimary!MTC_INST_SUFFIX! >nul 2>&1
sc start MTCopierStandby!MTC_INST_SUFFIX! >nul 2>&1
timeout /t 2 /nobreak >nul
goto :verify

:verify
echo.
echo =======================================================================
echo   Current Windows Services Status:
echo =======================================================================
sc query MTCopierPrimary!MTC_INST_SUFFIX! 2>nul | findstr "STATE"
sc query MTCopierStandby!MTC_INST_SUFFIX! 2>nul | findstr "STATE"
echo.
echo [SUCCESS] Service installation complete! Automatically starts on boot.
pause
