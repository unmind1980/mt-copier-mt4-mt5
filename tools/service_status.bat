@echo off
setlocal enabledelayedexpansion

echo =======================================================================
echo   MT-Copier - Windows Services Status
echo =======================================================================
echo.

sc query MTCopierPrimary
echo.
sc query MTCopierStandby
echo.
pause
