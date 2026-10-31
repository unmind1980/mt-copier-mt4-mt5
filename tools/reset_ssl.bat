@echo off
setlocal enabledelayedexpansion

echo ===================================================
echo   MT-Copier Central Hub - SSL/TLS Emergency Reset
echo ===================================================
echo.

set "CFG=tls_config.json"

if not exist "%CFG%" (
    echo [INFO] %CFG% not found. Hub is already running in default HTTP mode.
    goto :done
)

echo [1/3] Backing up current configuration to %CFG%.bak ...
copy /Y "%CFG%" "%CFG%.bak" >nul

echo [2/3] Disabling TLS/HTTPS in %CFG% ...
powershell -NoProfile -Command "(Get-Content '%CFG%' -Raw) -replace '\"enabled\"\s*:\s*true', '\"enabled\": false' | Set-Content '%CFG%' -Encoding UTF8"

echo [3/3] Verification:
powershell -NoProfile -Command "Get-Content '%CFG%' | Select-String '\"enabled\"'"

echo.
echo ===================================================
echo [SUCCESS] TLS/HTTPS has been disabled.
echo Hub will now accept unencrypted HTTP on its port.
echo If hub is running, restart it to apply the reset.
echo ===================================================
echo.

:done
pause
