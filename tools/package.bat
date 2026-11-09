@echo off
setlocal
set "HERE=%~dp0"
set "REPO=%HERE%..\"

REM Find python
set "PY="
where python >nul 2>nul
if not errorlevel 1 set "PY=python"
if not defined PY if exist "%USERPROFILE%\.workbuddy-ai\binaries\python\versions\3.13.12\python.exe" set "PY=%USERPROFILE%\.workbuddy-ai\binaries\python\versions\3.13.12\python.exe"

if not defined PY (
    echo [ERROR] Python not found. Please install Python 3 or add it to PATH.
    pause
    exit /b 1
)

"%PY%" "%HERE%package_releases.py" %*
if errorlevel 1 (
    echo.
    echo [FAILED] Packaging failed.
    pause
    exit /b 1
)

echo.
pause
