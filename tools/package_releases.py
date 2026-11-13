#!/usr/bin/env python3
"""
package_releases.py - Automated release bundler for mt-copier on GitHub.

Produces two official distribution packages:
1. mt-copier-direct-v{version}.zip
   - Standalone Direct P2P edition (Zero external processes, pure MT4/MT5 + ZeroMQ local loopback)
2. mt-copier-hub-suite-v{version}.zip
   - Complete enterprise edition with Central Hub (copier-hub.exe), locales, service scripts, and MT4/MT5 terminals.

All packaged instructions and documentation are primarily in English for global distribution.
"""

import hashlib
import os
import shutil
import sys
import zipfile
from pathlib import Path

VERSION = "1.1.0"

REPO_ROOT = Path(__file__).resolve().parent.parent
DIST_DIR = REPO_ROOT / "releases" / f"v{VERSION}"
TEMP_BUILD_DIR = REPO_ROOT / "releases" / "build_temp"

# Source paths
def _resolve_expert_dir(env_var: str, default_path: str, fallback_candidates: list) -> Path:
    val = os.environ.get(env_var)
    if val and Path(val).exists():
        return Path(val)
    def_p = Path(default_path)
    if def_p.exists():
        return def_p
    for cand in fallback_candidates:
        if cand.exists():
            return cand
    return def_p

MT4_EXPERT_SRC = _resolve_expert_dir(
    "MT4_EXPERT_SRC",
    r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\287469DEA9630EA94D0715D755974F1B\MQL4\Experts",
    [REPO_ROOT / "src" / "Experts", REPO_ROOT / "build" / "MT4"]
)
MT5_EXPERT_SRC = _resolve_expert_dir(
    "MT5_EXPERT_SRC",
    r"E:\MT5-Portable-Test\MQL5\Experts",
    [REPO_ROOT / "src" / "Experts", REPO_ROOT / "build" / "MT5"]
)

ZMQ_MT4_DLL = REPO_ROOT / "third_party" / "mql-zmq-master" / "Library" / "MT4" / "libzmq.dll"
ZMQ_MT5_DLL = REPO_ROOT / "third_party" / "mql-zmq-master" / "Library" / "MT5" / "libzmq.dll"

HUB_BIN = REPO_ROOT / "hub" / "target" / "release" / "copier-hub.exe"
HUB_DLL = REPO_ROOT / "third_party" / "zmq-prefix" / "lib" / "libzmq.dll"
LOCALES_DIR = REPO_ROOT / "locales"
LICENSE_FILE = REPO_ROOT / "LICENSE"


def check_sources():
    errors = []
    for f in [
        MT4_EXPERT_SRC / "CopierReceiver.ex4",
        MT4_EXPERT_SRC / "CopierSender.ex4",
        ZMQ_MT4_DLL,
        MT5_EXPERT_SRC / "CopierReceiver.ex5",
        MT5_EXPERT_SRC / "CopierSender.ex5",
        ZMQ_MT5_DLL,
        HUB_BIN,
        HUB_DLL,
    ]:
        if not f.exists():
            errors.append(f"Missing required artifact: {f}")
    if errors:
        for e in errors:
            print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def make_zip(source_dir: Path, output_zip: Path):
    with zipfile.ZipFile(output_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(source_dir):
            for file in sorted(files):
                full_path = Path(root) / file
                rel_path = full_path.relative_to(source_dir)
                z.write(full_path, arcname=rel_path.as_posix())


# =========================================================================
# 1. DIRECT P2P PACKAGE
# =========================================================================
DIRECT_README_EN = f"""================================================================================
mt-copier (Direct P2P Edition) - v{VERSION}
Ultra-Low-Latency Local Trade Copier for MetaTrader 4 & MetaTrader 5
================================================================================

Overview:
---------
This is the lightweight, zero-dependency Direct Mode edition of mt-copier.
It enables sub-10ms peer-to-peer trade replication between local terminals on
the same computer or VPS without running any central servers, external databases,
or background services.

Key Highlights:
- MT4 <-> MT5 Any-to-Any: Full bidirectional replication between 32-bit and 64-bit terminals.
- Ultra Low Latency: Sub-10ms execution via high-performance ZeroMQ memory pipes.
- Self-Contained ZeroMQ: MinGW-w64 standalone build - NO Microsoft Visual C++
  Redistributable (VC++ Runtime) required!
- Reliable State Engine: Trailing stop loss, signed break-even sync, and partial
  close tracking.

================================================================================
Quick Setup Guide (3 Steps)
================================================================================

Step 1: Copy Files to Your MetaTrader Data Folders
-------------------------------------------------
For each terminal, open MetaTrader -> Menu "File" -> Click "Open Data Folder":

For MT4 Terminals:
  1. Copy "MT4/MQL4/Experts/CopierSender.ex4" and "CopierReceiver.ex4"
     into your terminal's:  MQL4\\Experts\\
  2. Copy "MT4/MQL4/Libraries/libzmq.dll"
     into your terminal's:  MQL4\\Libraries\\

For MT5 Terminals:
  1. Copy "MT5/MQL5/Experts/CopierSender.ex5" and "CopierReceiver.ex5"
     into your terminal's:  MQL5\\Experts\\
  2. Copy "MT5/MQL5/Libraries/libzmq.dll"
     into your terminal's:  MQL5\\Libraries\\

Step 2: Enable DLL Imports & Automated Trading (CRITICAL!)
---------------------------------------------------------
In each MetaTrader terminal:
  1. Open menu: Tools -> Options -> "Expert Advisors" (or "Trade").
  2. Check [X] "Allow algorithmic trading" (or "Allow automated trading").
  3. Check [X] "Allow DLL imports".
  4. Click OK.

Step 3: Attach EAs to Chart & Start Copying
-------------------------------------------
1. On the Master/Sender Account:
   - Open any chart (e.g. EURUSD M1).
   - Drag "CopierSender" onto the chart.
   - Parameters: Default settings work out-of-the-box (Port 5000+acc%1000).
   - Click OK. A smiley face / blue hat will appear in the top-right corner.

2. On the Slave/Receiver Account:
   - Open any chart.
   - Drag "CopierReceiver" onto the chart.
   - In the "Inputs" tab:
     * HubEndpoint: leave EMPTY (empty = direct mode).
     * SenderIP / SenderPort: the sender's address and its EventsPort
       (shown in the sender's chart panel and Experts log).
     * SenderLotMode / SenderLotParam: lot sizing (default multiplier 1.0 = 1:1).
   - Click OK.

Done! Any market orders, pending orders, modifications, or closes placed on the
master account will instantly replicate to the receiver account.

================================================================================
License: MIT License. Open-source & institutional-grade trade replication.
Project Repository: https://github.com/unmind1980/mt-copier-mt4-mt5
================================================================================
"""

DIRECT_INSTALL_BAT = """@echo off
setlocal enabledelayedexpansion
title mt-copier Direct Installer
echo ===============================================================================
echo   mt-copier Direct Mode Auto-Deploy Tool
echo ===============================================================================
echo.
echo Scanning MetaTrader data folders in AppData...

set "COUNT=0"
for /d %%D in ("%APPDATA%\\MetaQuotes\\Terminal\\*") do (
    if exist "%%D\\MQL4" (
        echo [Found MT4] %%D
        if exist "%~dp0MT4\\MQL4\\Experts\\*.ex4" (
            copy /y "%~dp0MT4\\MQL4\\Experts\\*.ex4" "%%D\\MQL4\\Experts\\" >nul
            copy /y "%~dp0MT4\\MQL4\\Libraries\\*.dll" "%%D\\MQL4\\Libraries\\" >nul
            echo   -- Copied MT4 EAs and libzmq.dll
            set /a COUNT+=1
        )
    )
    if exist "%%D\\MQL5" (
        echo [Found MT5] %%D
        if exist "%~dp0MT5\\MQL5\\Experts\\*.ex5" (
            copy /y "%~dp0MT5\\MQL5\\Experts\\*.ex5" "%%D\\MQL5\\Experts\\" >nul
            copy /y "%~dp0MT5\\MQL5\\Libraries\\*.dll" "%%D\\MQL5\\Libraries\\" >nul
            echo   -- Copied MT5 EAs and libzmq.dll
            set /a COUNT+=1
        )
    )
)

echo.
echo ===============================================================================
if %COUNT% gtr 0 (
    echo   Deployment complete! Installed to %COUNT% terminal folder(s).
    echo   Please restart your MetaTrader terminals or right-click Navigator -^> Refresh.
) else (
    echo   No standard MetaTrader roaming data directories found.
    echo   Please manually copy MT4/ and MT5/ folders via terminal's File -^> Open Data Folder.
)
echo ===============================================================================
echo.
pause
"""

# =========================================================================
# 2. HUB SUITE PACKAGE
# =========================================================================
HUB_README_EN = f"""================================================================================
mt-copier (Complete Enterprise Hub Suite) - v{VERSION}
Institutional Multi-Node Trade Replication, High-Availability Cluster & Web Cockpit
================================================================================

Overview:
---------
This is the complete, full-stack enterprise edition of mt-copier.
It pairs MetaTrader 4 and MetaTrader 5 client nodes with a centralized Rust
Hub service providing:
- Real-time Web Cockpit & Multi-Node Monitor (:6010)
- Multi-Channel Instant Push Alerts (WeChat, Telegram, WeCom, DingTalk, Webhook)
- Active-Standby High-Availability (HA) cluster: journal replication, operator
  Promote, and two-phase failback (opt-in automatic promotion: --auto-promote)
- ZeroMQ CURVE 256-bit asymmetric encryption & native TLS 1.3 / HTTPS
- Centralized fleet configuration management & durable audit logging
- Background Windows Service daemons for 24/7 uninterrupted execution

Package Contents:
-----------------
1. Hub-Server/
   - copier-hub.exe           : High-performance Rust async Hub binary
   - libzmq.dll               : 64-bit MinGW ZeroMQ native engine
   - locales/                 : External language packs (es, ja, ru, zh-TW, etc.)
   - start_hub.bat            : Interactive console runner (Primary: 6000 / Web: 6010)
   - start_primary_ha.bat     : Launch Primary Hub in HA cluster mode
   - start_standby_ha.bat     : Launch Standby Hub in HA cluster mode
   - install_service.bat      : Register Hub as a background Windows Service
   - uninstall_service.bat    : Unregister Windows Service
   - reset_password.bat       : Reset WebUI dashboard credentials
2. Terminals/
   - MT4/                     : MetaTrader 4 EAs (.ex4) & 32-bit libzmq.dll
   - MT5/                     : MetaTrader 5 EAs (.ex5) & 64-bit libzmq.dll

================================================================================
Quick Start Guide
================================================================================

Step 1: Start the Central Hub Server
------------------------------------
- Go to "Hub-Server" folder.
- Double-click "start_hub.bat".
- The Hub will initialize:
    * ZMQ Order Router : 0.0.0.0:6000
    * Web Cockpit      : http://127.0.0.1:6010
- Open your browser at http://127.0.0.1:6010.
  (Initial startup generates a one-time admin password in .admin_bootstrap_password next to users.json).

Step 2: Install EAs into MetaTrader Terminals
--------------------------------------------
For each terminal (Master and Slaves):
- Open MetaTrader -> Menu "File" -> "Open Data Folder".
- Copy the contents of "Terminals/MT4/" (or MT5/) into the terminal folder:
    * .ex4/.ex5 files into Experts/
    * libzmq.dll into Libraries/
- In MetaTrader Tools -> Options -> Expert Advisors:
    * Check [X] "Allow algorithmic trading"
    * Check [X] "Allow DLL imports"

Step 3: Connect Terminals to Hub
--------------------------------
1. Attach CopierSender (on master terminal) or CopierReceiver (on slave terminal).
2. In the "Inputs" tab:
    * HubEndpoint : Set to "127.0.0.1:6000" (or your Hub VPS IP/domain:6000).
                    A non-empty HubEndpoint is what switches the EA to hub mode.
3. Click OK.
4. Check the Web Dashboard at http://127.0.0.1:6010: all active Sender and
   Receiver nodes, latency metrics, and real-time open positions will appear
   instantly in the fleet topology tree!

================================================================================
Running as a Background Windows Service (24/7 Production)
================================================================================
To run mt-copier without keeping a command prompt open:
1. Right-click "Hub-Server/install_service.bat" -> Run as Administrator.
2. The Hub is now registered as native Windows Service "MTCopierPrimary".
   It will start automatically on boot and restart upon unexpected termination.

================================================================================
High-Availability (HA) Dual-Active Setup
================================================================================
For institutional zero-downtime redundancy:
- Machine A (Primary) : Run "start_primary_ha.bat" (Port 6000 / Web 6010)
- Machine B (Standby) : Run "start_standby_ha.bat" (Port 6001 / Web 6011)
Terminals uplink to both Hubs concurrently, so trade data keeps flowing if
either Hub stops. Config, command, user and notification state replicate from
the Primary to the Standby. The Standby is READ-ONLY.

If the Primary fails, the Standby does NOT promote itself by default (this
avoids two writers after a network split). Confirm the Primary is really down,
then click "Promote" on the Standby dashboard (or POST /api/v1/cluster/promote).
To let the Standby promote itself after 30 s without peer contact, add
--auto-promote to start_standby_ha.bat - only when the two Hubs cannot be
partitioned from each other while both stay reachable by the terminals.

================================================================================
License: MIT License. Open-source & institutional-grade trade replication.
Project Repository: https://github.com/unmind1980/mt-copier-mt4-mt5
================================================================================
"""

HUB_START_BAT = """@echo off
setlocal
cd /d "%~dp0"
title mt-copier Central Hub (Standalone)
echo ===============================================================================
echo   mt-copier Central Hub Server - Standalone Console
echo ===============================================================================
echo   ZMQ Router    : 0.0.0.0:6000
echo   Web Dashboard : http://127.0.0.1:6010
echo ===============================================================================
echo.
copier-hub.exe --port 6000 --http 0.0.0.0:6010 %*
pause
"""

HUB_START_PRIMARY_HA_BAT = """@echo off
setlocal
cd /d "%~dp0"
title mt-copier Primary Hub [HA Cluster]
echo ===============================================================================
echo   mt-copier PRIMARY Hub (HA Cluster Mode)
echo ===============================================================================
echo   Local ZMQ     : 0.0.0.0:6000
echo   Web Dashboard : http://127.0.0.1:6010
echo   Peer ZMQ      : tcp://127.0.0.1:6001
echo   Peer API      : http://127.0.0.1:6011
echo ===============================================================================
echo.
copier-hub.exe --port 6000 --http 0.0.0.0:6010 --role primary --peer-api http://127.0.0.1:6011 --peer-zmq tcp://127.0.0.1:6001 %*
pause
"""

HUB_START_STANDBY_HA_BAT = """@echo off
setlocal
cd /d "%~dp0"
title mt-copier Standby Hub [HA Cluster]
echo ===============================================================================
echo   mt-copier STANDBY Hub (HA Cluster Mode)
echo ===============================================================================
echo   Local ZMQ     : 0.0.0.0:6001
echo   Web Dashboard : http://127.0.0.1:6011 (Read-Only)
echo   Peer ZMQ      : tcp://127.0.0.1:6000
echo   Peer API      : http://127.0.0.1:6010
echo   Promotion     : MANUAL (add --auto-promote to opt in)
echo ===============================================================================
echo.
copier-hub.exe --port 6001 --http 0.0.0.0:6011 --role standby --peer-api http://127.0.0.1:6010 --peer-zmq tcp://127.0.0.1:6000 %*
pause
"""

HUB_INSTALL_SVC_BAT = """@echo off
setlocal
cd /d "%~dp0"
echo ===============================================================================
echo   Registering mt-copier Primary Hub as Windows Service...
echo ===============================================================================
echo.
copier-hub.exe --service-install primary --port 6000 --http 0.0.0.0:6010
echo.
echo Service status:
copier-hub.exe --service-status primary
echo.
echo Use Windows Services (services.msc) to manage MTCopierPrimary,
echo or run copier-hub.exe --service-start primary / --service-stop primary.
pause
"""

HUB_UNINSTALL_SVC_BAT = """@echo off
setlocal
cd /d "%~dp0"
echo ===============================================================================
echo   Unregistering mt-copier Windows Service...
echo ===============================================================================
echo.
copier-hub.exe --service-uninstall primary
echo.
pause
"""

HUB_RESET_PWD_BAT = """@echo off
setlocal
cd /d "%~dp0"
echo ===============================================================================
echo   Reset Web Dashboard Admin Password
echo ===============================================================================
echo.
set /p NEWPASS="Enter new admin password: "
if "%NEWPASS%"=="" (
    echo Password cannot be empty.
    pause
    exit /b 1
)
copier-hub.exe --reset-password "%NEWPASS%"
if errorlevel 1 (
    echo.
    echo ERROR: Failed to update admin password.
    pause
    exit /b 1
)
echo.
echo Password updated successfully.
pause
"""


def build_direct_package():
    print(f"\n[*] Building Direct P2P package: mt-copier-direct-v{VERSION}.zip ...")
    pkg_dir = TEMP_BUILD_DIR / f"mt-copier-direct-v{VERSION}"
    if pkg_dir.exists():
        shutil.rmtree(pkg_dir, ignore_errors=True)
    pkg_dir.mkdir(parents=True)

    # MT4
    (pkg_dir / "MT4" / "MQL4" / "Experts").mkdir(parents=True)
    (pkg_dir / "MT4" / "MQL4" / "Libraries").mkdir(parents=True)
    shutil.copy2(MT4_EXPERT_SRC / "CopierReceiver.ex4", pkg_dir / "MT4" / "MQL4" / "Experts" / "CopierReceiver.ex4")
    shutil.copy2(MT4_EXPERT_SRC / "CopierSender.ex4", pkg_dir / "MT4" / "MQL4" / "Experts" / "CopierSender.ex4")
    shutil.copy2(ZMQ_MT4_DLL, pkg_dir / "MT4" / "MQL4" / "Libraries" / "libzmq.dll")

    # MT5
    (pkg_dir / "MT5" / "MQL5" / "Experts").mkdir(parents=True)
    (pkg_dir / "MT5" / "MQL5" / "Libraries").mkdir(parents=True)
    shutil.copy2(MT5_EXPERT_SRC / "CopierReceiver.ex5", pkg_dir / "MT5" / "MQL5" / "Experts" / "CopierReceiver.ex5")
    shutil.copy2(MT5_EXPERT_SRC / "CopierSender.ex5", pkg_dir / "MT5" / "MQL5" / "Experts" / "CopierSender.ex5")
    shutil.copy2(ZMQ_MT5_DLL, pkg_dir / "MT5" / "MQL5" / "Libraries" / "libzmq.dll")


    # Documentation and installer
    (pkg_dir / "README.txt").write_text(DIRECT_README_EN, encoding="utf-8")
    (pkg_dir / "install_direct.bat").write_text(DIRECT_INSTALL_BAT, encoding="utf-8")
    if LICENSE_FILE.exists():
        shutil.copy2(LICENSE_FILE, pkg_dir / "LICENSE.txt")

    zip_path = DIST_DIR / f"mt-copier-direct-v{VERSION}.zip"
    make_zip(pkg_dir, zip_path)
    print(f"[OK] Direct package generated: {zip_path} ({zip_path.stat().st_size:,} bytes)")
    return zip_path


def build_hub_suite_package():
    print(f"\n[*] Building Hub Suite package: mt-copier-hub-suite-v{VERSION}.zip ...")
    pkg_dir = TEMP_BUILD_DIR / f"mt-copier-hub-suite-v{VERSION}"
    if pkg_dir.exists():
        shutil.rmtree(pkg_dir, ignore_errors=True)
    pkg_dir.mkdir(parents=True)

    hub_dir = pkg_dir / "Hub-Server"
    hub_dir.mkdir(parents=True)

    # Hub executable & DLL
    shutil.copy2(HUB_BIN, hub_dir / "copier-hub.exe")
    shutil.copy2(HUB_DLL, hub_dir / "libzmq.dll")

    # Locales
    if LOCALES_DIR.exists():
        loc_dest = hub_dir / "locales"
        loc_dest.mkdir(parents=True)
        for j in LOCALES_DIR.glob("*.json"):
            shutil.copy2(j, loc_dest / j.name)

    # Launcher scripts
    (hub_dir / "start_hub.bat").write_text(HUB_START_BAT, encoding="utf-8")
    (hub_dir / "start_primary_ha.bat").write_text(HUB_START_PRIMARY_HA_BAT, encoding="utf-8")
    (hub_dir / "start_standby_ha.bat").write_text(HUB_START_STANDBY_HA_BAT, encoding="utf-8")
    (hub_dir / "install_service.bat").write_text(HUB_INSTALL_SVC_BAT, encoding="utf-8")
    (hub_dir / "uninstall_service.bat").write_text(HUB_UNINSTALL_SVC_BAT, encoding="utf-8")
    (hub_dir / "reset_password.bat").write_text(HUB_RESET_PWD_BAT, encoding="utf-8")

    # Terminals (Both MT4 and MT5)
    term_dir = pkg_dir / "Terminals"
    (term_dir / "MT4" / "MQL4" / "Experts").mkdir(parents=True)
    (term_dir / "MT4" / "MQL4" / "Libraries").mkdir(parents=True)
    shutil.copy2(MT4_EXPERT_SRC / "CopierReceiver.ex4", term_dir / "MT4" / "MQL4" / "Experts" / "CopierReceiver.ex4")
    shutil.copy2(MT4_EXPERT_SRC / "CopierSender.ex4", term_dir / "MT4" / "MQL4" / "Experts" / "CopierSender.ex4")
    shutil.copy2(ZMQ_MT4_DLL, term_dir / "MT4" / "MQL4" / "Libraries" / "libzmq.dll")

    (term_dir / "MT5" / "MQL5" / "Experts").mkdir(parents=True)
    (term_dir / "MT5" / "MQL5" / "Libraries").mkdir(parents=True)
    shutil.copy2(MT5_EXPERT_SRC / "CopierReceiver.ex5", term_dir / "MT5" / "MQL5" / "Experts" / "CopierReceiver.ex5")
    shutil.copy2(MT5_EXPERT_SRC / "CopierSender.ex5", term_dir / "MT5" / "MQL5" / "Experts" / "CopierSender.ex5")
    shutil.copy2(ZMQ_MT5_DLL, term_dir / "MT5" / "MQL5" / "Libraries" / "libzmq.dll")


    # Documentation
    (pkg_dir / "README.txt").write_text(HUB_README_EN, encoding="utf-8")
    if LICENSE_FILE.exists():
        shutil.copy2(LICENSE_FILE, pkg_dir / "LICENSE.txt")

    zip_path = DIST_DIR / f"mt-copier-hub-suite-v{VERSION}.zip"
    make_zip(pkg_dir, zip_path)
    print(f"[OK] Hub Suite package generated: {zip_path} ({zip_path.stat().st_size:,} bytes)")
    return zip_path


def main():
    print(f"===============================================================")
    print(f"  mt-copier Release Packaging Pipeline (Target: v{VERSION})")
    print(f"===============================================================")
    check_sources()

    DIST_DIR.mkdir(parents=True, exist_ok=True)
    TEMP_BUILD_DIR.mkdir(parents=True, exist_ok=True)

    direct_zip = build_direct_package()
    hub_zip = build_hub_suite_package()

    # Generate SHA-256 Checksums
    checksum_file = DIST_DIR / "SHA256SUMS.txt"
    with open(checksum_file, "w", encoding="utf-8") as f:
        for z in [direct_zip, hub_zip]:
            h = sha256_file(z)
            f.write(f"{h}  {z.name}\n")
            print(f"SHA-256 ({z.name}): {h}")

    # Clean up temp
    if TEMP_BUILD_DIR.exists():
        shutil.rmtree(TEMP_BUILD_DIR, ignore_errors=True)

    print(f"\n[SUCCESS] All release packages ready in: {DIST_DIR}")
    print(f"1. {direct_zip.name} ({direct_zip.stat().st_size:,} bytes)")
    print(f"2. {hub_zip.name} ({hub_zip.stat().st_size:,} bytes)")
    print(f"3. {checksum_file.name}")


if __name__ == "__main__":
    main()
