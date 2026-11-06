@echo off
REM ---------------------------------------------------------------------
REM selftest_run.bat - tools/selftest_run.sh for a cmd / double-click user.
REM
REM   tools\selftest_run.bat
REM   tools\selftest_run.bat --verbose
REM   tools\selftest_run.bat --target "E:/MT5-Portable-Test"
REM
REM It exists only to find bash. The logic lives in selftest_run.sh, so there
REM is exactly one copy of it.
REM ---------------------------------------------------------------------
setlocal

set "BASH="
for %%B in (
    "%ProgramFiles%\Git\bin\bash.exe"
    "%ProgramFiles(x86)%\Git\bin\bash.exe"
    "%ProgramFiles%\Git\usr\bin\bash.exe"
    "%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
) do (
    if not defined BASH if exist %%B set "BASH=%%~B"
)

if not defined BASH (
    where bash >nul 2>&1 && set "BASH=bash"
)

if not defined BASH (
    echo cannot find bash - install Git for Windows, or run tools\selftest_run.sh
    echo from Git Bash.
    exit /b 1
)

"%BASH%" "%~dp0selftest_run.sh" %*
exit /b %ERRORLEVEL%
