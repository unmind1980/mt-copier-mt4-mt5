@echo off
REM ---------------------------------------------------------------------
REM sniff.bat - run tools\zmq_sniff.py without having to know where Python
REM             lives. Double-click it, or run it from cmd:
REM
REM     tools\sniff.bat
REM     tools\sniff.bat --seconds 60
REM     tools\sniff.bat --host 127.0.0.1 --events 5565
REM
REM Any arguments are passed straight through to zmq_sniff.py.
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
  echo     "C:\Python313\python.exe" "%~dp0zmq_sniff.py" --seconds 30
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

"%PY%" "%HERE%zmq_sniff.py" %*
echo.
pause
