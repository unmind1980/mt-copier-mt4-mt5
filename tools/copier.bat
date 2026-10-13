@echo off
REM ---------------------------------------------------------------------
REM copier.bat - the Windows entry point for every tool in this folder.
REM
REM The tools themselves are shell scripts, which cmd cannot run. This
REM finds bash, forwards the sub-command to the matching script, and
REM passes any extra arguments through.
REM
REM     tools\copier.bat status
REM     tools\copier.bat build
REM     tools\copier.bat deploy
REM     tools\copier.bat compile
REM     tools\copier.bat phase2
REM     tools\copier.bat pilot
REM     tools\copier.bat clean --yes
REM     tools\copier.bat logcheck
REM     tools\copier.bat sniff --seconds 60
REM     tools\copier.bat hubtest
REM     tools\copier.bat hub
REM     tools\copier.bat hubrstest
REM     tools\copier.bat hubrs --build
REM     tools\copier.bat help
REM
REM (logcheck and sniff are Python and do not need bash; they are still
REM reachable from here so there is one command to remember.)
REM ---------------------------------------------------------------------
setlocal enabledelayedexpansion

set "HERE=%~dp0"
set "REPO=%HERE%..\"
REM --- bash wants forward slashes
set "REPO_FWD=%REPO:\=/%"
set "HERE_FWD=%HERE:\=/%"

set "CMD=%~1"
if "%CMD%"=="" set "CMD=help"

REM --- collect everything after the sub-command
set "ARGS="
shift
:collect
if "%~1"=="" goto dispatch
set "ARGS=%ARGS% %1"
shift
goto collect

:dispatch
if /i "%CMD%"=="help"     goto :help
if /i "%CMD%"=="status"   set "SCRIPT=status.sh"      & goto :runsh
if /i "%CMD%"=="build"    set "SCRIPT=build.sh"       & goto :runsh
if /i "%CMD%"=="deploy"   set "SCRIPT=deploy.sh"      & goto :runsh
if /i "%CMD%"=="compile"  set "SCRIPT=compile.sh"     & goto :runsh
if /i "%CMD%"=="clean"    set "SCRIPT=clean.sh"       & goto :runsh
if /i "%CMD%"=="pilot"    set "SCRIPT=pilot-setup.sh" & goto :runsh
if /i "%CMD%"=="phase2"   set "SCRIPT=phase2-setup.sh"& goto :runsh
if /i "%CMD%"=="deps"     set "SCRIPT=fetch-deps.sh"  & goto :runsh
if /i "%CMD%"=="logcheck" goto :logcheck
if /i "%CMD%"=="sniff"    goto :sniff
if /i "%CMD%"=="hub"      goto :hub
if /i "%CMD%"=="hubrs"    goto :hubrs
if /i "%CMD%"=="hubtest"  goto :hubtest
if /i "%CMD%"=="hubrstest" goto :hubrstest

echo.
echo   Unknown command: %CMD%
echo.
goto :help

REM ---------------------------------------------------------------------
:findbash
set "BASH="
where bash >nul 2>nul
if not errorlevel 1 set "BASH=bash"
if defined BASH goto :eof
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe" & goto :eof
if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe" & goto :eof
if exist "%USERPROFILE%\.workbuddy-ai\binaries\PortableGit\versions\1.2.0\usr\bin\bash.exe" set "BASH=%USERPROFILE%\.workbuddy-ai\binaries\PortableGit\versions\1.2.0\usr\bin\bash.exe" & goto :eof
goto :eof

:runsh
call :findbash
if not defined BASH (
  echo.
  echo   Cannot find bash on this machine.
  echo   Install Git for Windows from https://git-scm.com/download/win
  echo   ^(which also gives you the shell these tools are written in^).
  echo.
  pause
  exit /b 1
)
"%BASH%" "%REPO_FWD%tools/%SCRIPT%"%ARGS%
goto :end

:logcheck
call "%HERE%logcheck.bat"%ARGS%
goto :end

:sniff
call "%HERE%sniff.bat"%ARGS%
goto :end

:hub
REM --- the Python PROTOTYPE hub. Still the reference implementation: the Rust
REM --- one is only correct in so far as it passes the same routing suite.
call "%HERE%hub.bat"%ARGS%
goto :end

:hubrs
REM --- the RUST hub. Same behaviour, same stats format, built against the
REM --- EAs' own libzmq. See hub/README.md.
call "%HERE%hubrs.bat"%ARGS%
goto :end

:hubtest
REM --- the routing self-test. Needs no terminal and no broker: it drives the
REM --- hub with a fake sender and fake receivers, so it is the thing to run
REM --- BEFORE pointing a real EA at it. hub.bat handles the flag, so the
REM --- Python-finding logic stays in one place.
call "%HERE%hub.bat" --selftest
goto :end

:hubrstest
REM --- the SAME routing suite, run against the Rust binary. Two green runs
REM --- against the same 13 checks is what makes "the Rust port is aligned"
REM --- a measurement rather than an assertion.
call "%HERE%hubrs.bat" --selftest
goto :end

REM ---------------------------------------------------------------------
:help
echo.
echo   Trade copier tools
echo.
echo     tools\copier.bat status              what terminals exist, what is deployed
echo     tools\copier.bat status --all        every terminal on the machine
echo     tools\copier.bat build               deploy THEN compile (the normal one command)
echo     tools\copier.bat deploy              push sources + DLLs to the targets
echo     tools\copier.bat deploy --list       show what would be touched
echo     tools\copier.bat compile             compile everywhere, print the logs
echo     tools\copier.bat phase2              prepare P2 phase 2 (MT4 as sender)
echo     tools\copier.bat pilot               prepare the MT5 loopback pilot
echo     tools\copier.bat logcheck            verdict from the copier logs
echo     tools\copier.bat sniff               watch what the sender publishes
echo     tools\copier.bat hubtest             check the prototype hub routes correctly
echo     tools\copier.bat hub                 RUN the prototype hub ^(Python^)
echo     tools\copier.bat hubrstest           the SAME checks, against the Rust hub
echo     tools\copier.bat hubrs --build       build the Rust hub, then run it
echo     tools\copier.bat hub                 RUN the prototype hub (Ctrl-C to stop)
echo     tools\copier.bat clean --yes         remove portable-target build caches
echo     tools\copier.bat deps                download mql-zmq
echo.
echo   Which terminals are used is set in tools\targets.conf.
echo.
echo   If a command says "Cannot find bash", install Git for Windows -
echo   these tools are shell scripts and cmd cannot run them directly.
echo.
pause
exit /b 0

:end
REM --- keep the window open when this was double-clicked
if /i "%COPIER_NO_PAUSE%"=="1" goto :reallyend
echo.
pause
:reallyend
endlocal
