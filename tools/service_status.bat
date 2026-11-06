@echo off
setlocal enabledelayedexpansion

echo =======================================================================
echo   MT-Copier - Windows Services Status
echo =======================================================================
echo.

rem --- H4: optional instance suffix, so a second Primary/Standby on this host can be
rem --- started/stopped/queried without touching the first one. Unset = historic names.
set "MTC_INST_SUFFIX="
if defined MTC_INSTANCE set "MTC_INST_SUFFIX=_%MTC_INSTANCE%"
sc query MTCopierPrimary%MTC_INST_SUFFIX%
echo.
sc query MTCopierStandby%MTC_INST_SUFFIX%
echo.
pause
