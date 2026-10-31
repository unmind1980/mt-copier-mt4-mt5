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
    echo   "Run as administrator" (以管理员身份运行)
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
echo   [可选设置] 配置对端备机 VPS:
echo   如果您的架构包含备用 VPS，请输入备机 VPS 的 IP (例如 168.100.200.50)。
echo   如果仅单机运行 (无备机)，请直接按回车跳过 (默认单机模式):
echo =======================================================================
set "PEER_IP="
set /p PEER_IP="对端备机 IP (回车留空为单机模式): "

echo.
echo [1/2] Installing MTCopierPrimary service...
if "!PEER_IP!"=="" (
    echo [模式] 单机独立运行模式 (Standalone - 无对端备机)
    "%BIN%" --service-install primary --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role primary
) else (
    echo [模式] 主备双活集群模式 (对端备机: !PEER_IP!)
    "%BIN%" --service-install primary --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role primary --peer-api http://!PEER_IP!:6010 --peer-zmq tcp://!PEER_IP!:6000
)
if %errorLevel% neq 0 (
    echo [ERROR] Failed to install MTCopierPrimary service.
    pause
    exit /b 1
)
echo [2/2] Starting MTCopierPrimary service...
sc start MTCopierPrimary >nul 2>&1
timeout /t 2 /nobreak >nul
goto :verify

:install_standby
echo.
if not exist "standby_data" mkdir "standby_data"
echo =======================================================================
echo   [配置对端主机 VPS]:
echo   请输入对端主机 VPS 的 IP 地址 (例如 149.135.109.18)。
echo   若暂未就绪或稍后在 Web 界面配置，请直接按回车跳过:
echo =======================================================================
set "PEER_IP="
set /p PEER_IP="对端主机 IP (回车跳过): "

echo.
echo [1/2] Installing MTCopierStandby service...
if "!PEER_IP!"=="" (
    echo [模式] 备机初始化 (等待后续通过 Web 界面关联主机)
    "%BIN%" --service-install standby --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role standby --cluster-state standby_data\cluster_state.json --config standby_data\config_revisions.jsonl --commands standby_data\commands.jsonl --users standby_data\users.json --notifications standby_data\alert_channels.json --curve-clients standby_data\curve_clients.txt --curve-keys curve_hub.keys --audit standby_data\audit.jsonl
) else (
    echo [模式] 备机热备连接模式 (对端主机: !PEER_IP!)
    "%BIN%" --service-install standby --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role standby --peer-api http://!PEER_IP!:6010 --peer-zmq tcp://!PEER_IP!:6000 --cluster-state standby_data\cluster_state.json --config standby_data\config_revisions.jsonl --commands standby_data\commands.jsonl --users standby_data\users.json --notifications standby_data\alert_channels.json --curve-clients standby_data\curve_clients.txt --curve-keys curve_hub.keys --audit standby_data\audit.jsonl
)
if %errorLevel% neq 0 (
    echo [ERROR] Failed to install MTCopierStandby service.
    pause
    exit /b 1
)
echo [2/2] Starting MTCopierStandby service...
sc start MTCopierStandby >nul 2>&1
timeout /t 2 /nobreak >nul
goto :verify

:install_both
echo.
if not exist "standby_data" mkdir "standby_data"
echo [单机双活开发测试] 同时在本地安装 Primary(6000/6010) 与 Standby(6001/6011)...
"%BIN%" --service-install primary --workdir "%REPO%" --port 6000 --http 0.0.0.0:6010 --role primary --peer-api http://127.0.0.1:6011 --peer-zmq tcp://127.0.0.1:6001
"%BIN%" --service-install standby --workdir "%REPO%" --port 6001 --http 0.0.0.0:6011 --role standby --peer-api http://127.0.0.1:6010 --peer-zmq tcp://127.0.0.1:6000 --cluster-state standby_data\cluster_state.json --config standby_data\config_revisions.jsonl --commands standby_data\commands.jsonl --users standby_data\users.json --notifications standby_data\alert_channels.json --curve-clients standby_data\curve_clients.txt --curve-keys curve_hub.keys --audit standby_data\audit.jsonl
echo Starting services...
sc start MTCopierPrimary >nul 2>&1
sc start MTCopierStandby >nul 2>&1
timeout /t 2 /nobreak >nul
goto :verify

:verify
echo.
echo =======================================================================
echo   Current Windows Services Status:
echo =======================================================================
sc query MTCopierPrimary 2>nul | findstr "STATE"
sc query MTCopierStandby 2>nul | findstr "STATE"
echo.
echo [SUCCESS] Service installation complete! Automatically starts on boot.
pause
