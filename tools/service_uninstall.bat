@echo off
setlocal enabledelayedexpansion

echo =======================================================================
echo   MT-Copier - Uninstall Windows Services
echo =======================================================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Administrator privileges are required to uninstall Windows Services.
    echo Please right-click this batch file and choose "Run as administrator".
    pause
    exit /b 1
)

set "HERE=%~dp0"
set "REPO=%HERE%.."
cd /d "%REPO%"

set "BIN=%REPO%\hub\target\release\copier-hub.exe"

echo Please choose which Windows Service to uninstall from this computer:
echo.
echo   [1] Uninstall Primary Hub Service (MTCopierPrimary)
echo   [2] Uninstall Standby Hub Service (MTCopierStandby)
echo   [3] Uninstall BOTH Services (Clean reset)
echo   [0] Cancel
echo.
set /p CHOICE="Enter choice [1, 2, 3 or 0]: "

if "%CHOICE%"=="1" goto :uninst_primary
if "%CHOICE%"=="2" goto :uninst_standby
if "%CHOICE%"=="3" goto :uninst_both
echo Cancelled.
exit /b 0

:uninst_primary
echo.
echo Stopping and removing MTCopierPrimary service...
if exist "%BIN%" (
    "%BIN%" --service-uninstall primary
) else (
    sc stop MTCopierPrimary >nul 2>&1
    sc delete MTCopierPrimary >nul 2>&1
)
goto :done

:uninst_standby
echo.
echo Stopping and removing MTCopierStandby service...
if exist "%BIN%" (
    "%BIN%" --service-uninstall standby
) else (
    sc stop MTCopierStandby >nul 2>&1
    sc delete MTCopierStandby >nul 2>&1
)
goto :done

:uninst_both
echo.
echo Stopping and removing ALL MT-Copier services...
if exist "%BIN%" (
    "%BIN%" --service-uninstall primary
    "%BIN%" --service-uninstall standby
) else (
    sc stop MTCopierPrimary >nul 2>&1
    sc delete MTCopierPrimary >nul 2>&1
    sc stop MTCopierStandby >nul 2>&1
    sc delete MTCopierStandby >nul 2>&1
)
goto :done

:done
echo.
echo [SUCCESS] Operation complete.
pause
