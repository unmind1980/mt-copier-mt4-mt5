@echo off
REM ---------------------------------------------------------------------
REM hublog.bat - run the Rust hub with its output written to a FILE as well.
REM
REM     tools\hublog.bat                run it on the default port
REM     tools\hublog.bat --port 6100
REM     tools\hublog.bat --stats-every 30
REM
REM WHY THIS EXISTS
REM ===============
REM The hub's only observability is its stdout - the traffic stats, the node
REM registry, and since M3 the position view all live there and nowhere else.
REM Started from hubrs.bat that output goes to a console window and dies with
REM it, so the only way to read it is to be sitting in front of the machine.
REM That is a bad property for the one component whose whole job is to report
REM what the rest of the system is doing.
REM
REM This runs the same binary with the same arguments and tees the output to
REM hub.log next to the repo root. Nothing about the hub changes - it is the
REM launcher that differs, and only in where stdout goes.
REM
REM The log is TRUNCATED at each start, so it always describes the CURRENT run
REM rather than a growing pile. If you need history across restarts, copy it
REM aside first.
REM
REM The console still shows everything live (that is what Tee does). To watch
REM the file instead, in another window:
REM     powershell -NoProfile -Command "Get-Content hub.log -Wait"
REM ---------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
set "REPO=%HERE%.."
set "BIN=%REPO%\hub\target\release\copier-hub.exe"
set "LOG=%REPO%\hub.log"

if not exist "%BIN%" (
  echo.
  echo   Cannot find the hub binary:
  echo     %BIN%
  echo.
  echo   Build it first:
  echo     tools\hubrs.bat --build
  echo     ^(or: bash hub/build.sh --release^)
  echo.
  pause
  exit /b 1
)

echo.
echo   Starting the RUST hub. Press Ctrl-C to stop it.
echo   Live output below, and also written to:
echo     %LOG%
echo.

REM --- Tee rather than a bare redirect, so the console keeps the live view it
REM --- had before.
REM ---
REM --- NO -Encoding ON Tee-Object. It looks like the obvious flag and it does
REM --- not exist on Windows PowerShell 5.1: every run dies with
REM --- "A parameter cannot be found that matches parameter name 'Encoding'"
REM --- before the hub starts at all. Measured, 2026-10-13.
REM ---
REM --- What it writes is UTF-16 LE with a BOM. That is deliberate enough to be
REM --- worth knowing rather than a bug: every reader that handles the MT5
REM --- logs already reads it, and that includes the checks this project runs
REM --- against hub output.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "& '%BIN%' %* 2>&1 | Tee-Object -FilePath '%LOG%'"

echo.
echo   Hub stopped. Its output is in:
echo     %LOG%
echo.
pause
