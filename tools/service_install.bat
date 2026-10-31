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
echo [1/2] Installing MTCopierPrimary service...
"%BIN%" --service-install primary --workdir "%REPO%"
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
echo [1/2] Installing MTCopierStandby service...
"%BIN%" --service-install standby --workdir "%REPO%"
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
echo [1/4] Installing MTCopierPrimary service...
"%BIN%" --service-install primary --workdir "%REPO%"
echo [2/4] Installing MTCopierStandby service...
"%BIN%" --service-install standby --workdir "%REPO%"
echo [3/4] Starting MTCopierPrimary service...
sc start MTCopierPrimary >nul 2>&1
echo [4/4] Starting MTCopierStandby service...
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
