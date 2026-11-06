@echo off
setlocal enabledelayedexpansion

echo =======================================================================
echo   MT-Copier - Start Windows Services (Primary + Standby)
echo =======================================================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Administrator privileges are required to start Windows Services.
    echo Please right-click this batch file and choose "Run as administrator".
    pause
    exit /b 1
)

rem --- H4: optional instance suffix, so a second Primary/Standby on this host can be
rem --- started/stopped/queried without touching the first one. Unset = historic names.
set "MTC_INST_SUFFIX="
if defined MTC_INSTANCE set "MTC_INST_SUFFIX=_%MTC_INSTANCE%"
echo Starting MTCopierPrimary%MTC_INST_SUFFIX%...
sc start MTCopierPrimary%MTC_INST_SUFFIX%
echo.
echo Starting MTCopierStandby%MTC_INST_SUFFIX%...
sc start MTCopierStandby%MTC_INST_SUFFIX%
echo.
timeout /t 2 /nobreak >nul

sc query MTCopierPrimary%MTC_INST_SUFFIX% | findstr "STATE"
sc query MTCopierStandby%MTC_INST_SUFFIX% | findstr "STATE"
echo.
pause
