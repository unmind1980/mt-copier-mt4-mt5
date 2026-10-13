@echo off
REM ---------------------------------------------------------------------
REM hubrs.bat - run the RUST hub (hub/target/release/copier-hub.exe).
REM
REM     tools\hubrs.bat                 run it on the default port
REM     tools\hubrs.bat --port 6100
REM     tools\hubrs.bat --verbose
REM     tools\hubrs.bat --build         build it first, then run
REM     tools\hubrs.bat --selftest      run the routing contract against it
REM     tools\hubrs.bat --selftest --python   ...against the Python prototype
REM
REM WHY BOTH HUBS STILL EXIST
REM =========================
REM
REM tools\hub_proto.py is the prototype the protocol was designed against, and
REM it is the REFERENCE: tools\hub_proto_test.py passes against it, and the
REM Rust binary is only correct in so far as it passes the same suite. Keeping
REM both runnable is what makes "the Rust version behaves the same" a
REM measurement instead of a claim - so do not delete the prototype when this
REM one becomes the default.
REM
REM The Rust hub is a faithful port of that prototype. Same two-frame
REM forwarding, same '@' handling, same PONG, same stats format. See hub/README.md
REM for why it is pinned to zmq 0.9.2 and how it links the EAs' own libzmq.
REM ---------------------------------------------------------------------
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "REPO=%HERE%.."
set "BIN=%REPO%\hub\target\release\copier-hub.exe"

set "PY="
for %%c in (
  "%USERPROFILE%\.workbuddy-ai\binaries\python\envs\default\Scripts\python.exe"
  "%USERPROFILE%\.workbuddy-ai\binaries\python\versions\3.13.12\python.exe"
) do (
  if not defined PY if exist %%c set "PY=%%~c"
)

REM --- --build: run the bootstrap script, which sets RUSTUP_HOME, CARGO_HOME,
REM --- LIBZMQ_PREFIX and PATH. Doing it by hand in cmd is possible and has
REM --- three separate ways to go wrong; see hub/build.sh.
if "%~1"=="--build" (
  echo   Building the Rust hub...
  bash "%REPO%/hub/build.sh" --release
  if errorlevel 1 (
    echo.
    echo   Build failed. hub/build.sh prints what to install.
    pause
    exit /b 1
  )
  shift
)

if not exist "%BIN%" (
  echo.
  echo   The Rust hub has not been built yet.
  echo.
  echo   Build it with:
  echo     tools\hubrs.bat --build
  echo.
  echo   ^(or, from Git Bash:  bash hub/build.sh --release^)
  echo.
  pause
  exit /b 1
)

REM --- --selftest: run the routing contract, against whichever hub was asked
REM --- for. The suite is identical on purpose - that is the whole point.
if "%~1"=="--selftest" (
  shift
  if not defined PY (
    echo   --selftest needs Python ^(it drives the hub over real sockets^).
    pause
    exit /b 1
  )
  if "%~1"=="--python" (
    "%PY%" "%HERE%hub_proto_test.py" --port 6112
  ) else (
    REM --- --registry because the Phase 2 registry exists only in this hub;
    REM --- the Python prototype is frozen at Phase 1 and would fail those
    REM --- checks for the right reason and the wrong result.
    "%PY%" "%HERE%hub_proto_test.py" --hub "%BIN%" --port 6113 --registry
  )
  echo.
  pause
  exit /b %errorlevel%
)

echo.
echo   Starting the RUST hub. Press Ctrl-C to stop it.
echo   Nothing is persisted - it forwards what it receives.
echo.
"%BIN%" %*
echo.
pause
