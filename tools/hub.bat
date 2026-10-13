@echo off
REM ---------------------------------------------------------------------
REM hub.bat - run tools\hub_proto.py without having to know where Python
REM           lives. Double-click it, or run it from cmd:
REM
REM     tools\hub.bat
REM     tools\hub.bat --port 6100
REM     tools\hub.bat --verbose
REM
REM Any arguments are passed straight through to hub_proto.py.
REM
REM WHY THIS EXISTS: double-clicking a .py on a machine with no Python file
REM association gets you a Windows dialog offering to find an app for it,
REM and `python` is not on PATH in a stock cmd window either. Both failures
REM look like "the script is broken" when nothing is wrong with the script.
REM
REM This is the Phase 1 PROTOTYPE hub - pure forwarding, no config, no
REM registry. It runs until you press Ctrl-C.
REM ---------------------------------------------------------------------
setlocal enabledelayedexpansion
set "HERE=%~dp0"

set "PY="
for %%c in (
  "%USERPROFILE%\.workbuddy-ai\binaries\python\envs\default\Scripts\python.exe"
  "%USERPROFILE%\.workbuddy-ai\binaries\python\versions\3.13.12\python.exe"
) do (
  if not defined PY if exist %%c set "PY=%%~c"
)

if not defined PY (
  where py >nul 2>nul
  if not errorlevel 1 set "PY=py"
)
if not defined PY (
  where python >nul 2>nul
  if not errorlevel 1 set "PY=python"
)

if not defined PY (
  echo.
  echo   Cannot find Python on this machine.
  echo.
  echo   Either install it from https://www.python.org/downloads/
  echo   ^(tick "Add python.exe to PATH" during setup^), or run the script
  echo   with a full path, for example:
  echo.
  echo     "C:\Python313\python.exe" "%~dp0hub_proto.py" --port 6000
  echo.
  pause
  exit /b 1
)

REM --- pyzmq is required. Install it once, silently, if it is missing.
"%PY%" -c "import zmq" >nul 2>nul
if errorlevel 1 (
  echo   pyzmq is missing - installing it once, please wait...
  "%PY%" -m pip install --quiet --disable-pip-version-check pyzmq
  "%PY%" -c "import zmq" >nul 2>nul
  if errorlevel 1 (
    echo.
    echo   Could not install pyzmq. Run this by hand and read the error:
    echo     "%PY%" -m pip install pyzmq
    echo.
    pause
    exit /b 1
  )
)

echo.
echo   Starting the Phase 1 prototype hub. Press Ctrl-C to stop it.
echo   Nothing here is persisted - it just forwards what it receives.
echo.

REM --- `--selftest` runs the routing test instead of the hub itself.
REM ---
REM --- It is handled HERE rather than in a second wrapper so the "find
REM --- Python, install pyzmq" logic exists in exactly one place - the
REM --- alternative is two copies that disagree the day Python moves.
if "%~1"=="--selftest" (
  "%PY%" "%HERE%hub_proto_test.py"
  echo.
  pause
  exit /b %errorlevel%
)

"%PY%" "%HERE%hub_proto.py" %*
echo.
pause
