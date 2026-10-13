@echo off
REM ---------------------------------------------------------------------
REM logcheck.bat - run tools\logcheck.py without having to know where
REM                Python lives. Double-click it, or run it from cmd:
REM
REM     tools\logcheck.bat                 (discovers the logs itself)
REM     tools\logcheck.bat --json
REM
REM Discovery is done by logcheck.py --discover, which walks the terminal
REM data folders and honours tools\targets.conf if it exists.
REM ---------------------------------------------------------------------
setlocal
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
  echo   Install it from https://www.python.org/downloads/
  echo   ^(tick "Add python.exe to PATH" during setup^).
  echo.
  pause
  exit /b 1
)

if "%~1"=="" (
  "%PY%" "%HERE%logcheck.py" --discover
) else (
  "%PY%" "%HERE%logcheck.py" %*
)
echo.
pause
