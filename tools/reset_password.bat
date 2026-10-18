@echo off
REM ---------------------------------------------------------------------
REM reset_password.bat - reset or set the admin password for copier-hub
REM
REM Usage:
REM     tools\reset_password.bat
REM     tools\reset_password.bat --user admin --password mysecret123
REM ---------------------------------------------------------------------
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "REPO=%HERE%.."

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
  echo   Cannot find Python to run password reset.
  echo.
  pause
  exit /b 1
)

"%PY%" "%HERE%reset_password.py" %*
pause
