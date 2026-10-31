@echo off
setlocal enabledelayedexpansion

echo =======================================================================
echo   MT-Copier - Windows Services Installation (Primary + Standby)
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
if not exist "standby_data" mkdir "standby_data"

echo [1/4] Installing MTCopierPrimary service (Port 6000 ZMQ / Port 6010 HTTP / Port 443 HTTPS)...
"%BIN%" --service-install primary --workdir "%REPO%"
if %errorLevel% neq 0 (
    echo [ERROR] Failed to install MTCopierPrimary service.
    pause
    exit /b 1
)

echo [2/4] Installing MTCopierStandby service (Port 6001 ZMQ / Port 6011 HTTP)...
"%BIN%" --service-install standby --workdir "%REPO%"
if %errorLevel% neq 0 (
    echo [ERROR] Failed to install MTCopierStandby service.
    pause
    exit /b 1
)

echo [3/4] Starting MTCopierPrimary service...
sc start MTCopierPrimary >nul 2>&1
timeout /t 2 /nobreak >nul

echo [4/4] Starting MTCopierStandby service...
sc start MTCopierStandby >nul 2>&1
timeout /t 2 /nobreak >nul

echo.
echo =======================================================================
echo   Current Windows Services Status:
echo =======================================================================
sc query MTCopierPrimary | findstr "STATE"
sc query MTCopierStandby | findstr "STATE"

echo.
echo [SUCCESS] Both services installed and configured for automatic startup on boot!
echo   - Log file: %REPO%\hub_mtcopierprimary_service.log
echo   - Log file: %REPO%\hub_mtcopierstandby_service.log
echo.
pause
