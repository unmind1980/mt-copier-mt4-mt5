@echo off
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "REPO=%HERE%.."

echo =======================================================================
echo   mt-copier Dual-Active HA Hubs Launcher (Primary + Standby)
echo =======================================================================
echo.
echo   [1] Primary Hub : Port 6000 (ZMQ) / http://127.0.0.1:6010 (Web)
echo   [2] Standby Hub : Port 6001 (ZMQ) / http://127.0.0.1:6011 (Web)
echo.
rem --- Settle the cluster token BEFORE either hub starts.
rem ---
rem --- Both hubs must present the SAME token, or every peer probe answers 401
rem --- and both dashboards say "Peer: Offline" while both are running fine -
rem --- and failover can never work. Minting it here, once, removes the race:
rem --- this script starts the primary and the standby two seconds apart, so
rem --- leaving the mint to the primary meant the standby was betting that the
rem --- file had already been written. When it had not, the standby either found
rem --- nothing usable or, worse, found whatever text was in the file.
cd /d "%REPO%"
set "CP_OLD_PUBLIC_TOKEN=mtc_shared_cluster_token_2026"
set "TOK="
if exist "cluster_token.txt" set /p TOK=<"cluster_token.txt"
if /i "!TOK!"=="%CP_OLD_PUBLIC_TOKEN%" set "TOK="
rem --- A token cannot contain a space. This rejects a file clobbered by a stray
rem --- redirection (see the note in start_primary.bat), which is exactly how a
rem --- 45-character status line once became one hub's credential.
if defined TOK (
    echo !TOK!| findstr /c:" " >nul && set "TOK="
)
if not defined TOK (
    for /f "delims=" %%i in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString()+[guid]::NewGuid().ToString()"') do set "TOK=%%i"
    if not defined TOK (
        echo [ERROR] Cannot mint a cluster token ^(PowerShell unavailable^).
        echo         Create cluster_token.txt by hand with a long random string.
        pause
        exit /b 1
    )
    > "cluster_token.txt" echo !TOK!
    echo   [cluster] Minted a new random cluster token, written to %CD%\cluster_token.txt
) else (
    echo   [cluster] Reusing the existing cluster token from %CD%\cluster_token.txt
)
echo.

echo   Launching both Hubs in separate console windows...
echo.

start "mt-copier Hub - PRIMARY (6000 / 6010)" cmd /k "%HERE%start_primary.bat"
timeout /t 3 /nobreak >nul
start "mt-copier Hub - STANDBY (6001 / 6011)" cmd /k "%HERE%start_standby.bat"

echo   Both Hubs are now running!
echo   Primary Web Dashboard: http://127.0.0.1:6010
echo   Standby Web Dashboard: http://127.0.0.1:6011
echo.
timeout /t 5
