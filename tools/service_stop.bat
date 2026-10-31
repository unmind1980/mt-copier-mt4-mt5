@echo off
setlocal enabledelayedexpansion

echo =======================================================================
echo   MT-Copier - Stop Windows Services (Primary + Standby)
echo =======================================================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Administrator privileges are required to stop Windows Services.
    echo Please right-click this batch file and choose "Run as administrator".
    pause
    exit /b 1
)

echo Stopping MTCopierPrimary...
sc stop MTCopierPrimary
echo.
echo Stopping MTCopierStandby...
sc stop MTCopierStandby
echo.
timeout /t 2 /nobreak >nul

sc query MTCopierPrimary | findstr "STATE"
sc query MTCopierStandby | findstr "STATE"
echo.
pause
