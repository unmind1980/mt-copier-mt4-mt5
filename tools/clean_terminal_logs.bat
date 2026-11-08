@echo off
REM ---------------------------------------------------------------------
REM clean_terminal_logs.bat - prune MetaTrader daily logs and build caches
REM
REM Usage:
REM   tools\clean_terminal_logs.bat           preview what would be removed
REM   tools\clean_terminal_logs.bat --yes     actually remove expired logs
REM ---------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
set "YES_FLAG="

if "%~1"=="--yes" set "YES_FLAG=-Yes"
if "%~1"=="-y" set "YES_FLAG=-Yes"
if "%~1"=="-Yes" set "YES_FLAG=-Yes"

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%clean_terminal_logs.ps1" %YES_FLAG%
