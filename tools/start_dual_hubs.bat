@echo off
setlocal
set "HERE=%~dp0"

echo =======================================================================
echo   mt-copier Dual-Active HA Hubs Launcher (Primary + Standby)
echo =======================================================================
echo.
echo   [1] Primary Hub : Port 6000 (ZMQ) / http://127.0.0.1:6010 (Web)
echo   [2] Standby Hub : Port 6001 (ZMQ) / http://127.0.0.1:6011 (Web)
echo.
echo   Launching both Hubs in separate console windows...
echo.

start "mt-copier Hub - PRIMARY (6000 / 6010)" cmd /k "%HERE%start_primary.bat"
timeout /t 2 /nobreak >nul
start "mt-copier Hub - STANDBY (6001 / 6011)" cmd /k "%HERE%start_standby.bat"

echo   Both Hubs are now running!
echo   Primary Web Dashboard: http://127.0.0.1:6010
echo   Standby Web Dashboard: http://127.0.0.1:6011
echo.
timeout /t 5
