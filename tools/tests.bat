@echo off
REM ---------------------------------------------------------------------
REM tests.bat - tools/tests.sh for a cmd / double-click user.
REM
REM   tools\tests.bat
REM   tools\tests.bat --all
REM
REM It exists only to find bash. The logic, the interpreter search and the
REM suite list all live in tests.sh, so there is exactly one copy of them.
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
    echo cannot find bash - install Git for Windows, or run tools\tests.sh
    echo from Git Bash.
    exit /b 1
)

REM %* passes --all through, and drops through to nothing when empty.
"%BASH%" "%~dp0tests.sh" %*
exit /b %ERRORLEVEL%
