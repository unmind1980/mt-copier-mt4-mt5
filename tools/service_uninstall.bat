@echo off
setlocal enabledelayedexpansion

echo =======================================================================
echo   MT-Copier - Windows Services Uninstallation
echo =======================================================================
echo.

rem --- Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Administrator privileges are required to uninstall Windows Services.
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
    echo [INFO] copier-hub.exe not found at release path, falling back to sc.exe...
    sc stop MTCopierPrimary >nul 2>&1
    sc delete MTCopierPrimary >nul 2>&1
    sc stop MTCopierStandby >nul 2>&1
    sc delete MTCopierStandby >nul 2>&1
    goto :done
)

echo [1/2] Stopping and removing MTCopierPrimary service...
"%BIN%" --service-uninstall primary

echo [2/2] Stopping and removing MTCopierStandby service...
"%BIN%" --service-uninstall standby

:done
echo.
echo =======================================================================
echo [SUCCESS] MT-Copier Windows Services have been completely uninstalled.
echo =======================================================================
echo.
pause
