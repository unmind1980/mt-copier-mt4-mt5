#!/usr/bin/env python3
"""
tools/run_dual_hubs.py - Launches and detaches Primary and Standby copier-hub processes cleanly on Windows.
"""
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(REPO, "hub", "target", "release", "copier-hub.exe")

env = os.environ.copy()
for k in ["http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]:
    env.pop(k, None)

env["PATH"] = os.path.join(REPO, "third_party", "zmq-prefix", "lib") + ";" + env.get("PATH", "")

# Ensure cluster token exists
tok_file = os.path.join(REPO, "cluster_token.txt")
if not os.path.exists(tok_file):
    import uuid
    tok = str(uuid.uuid4()) + str(uuid.uuid4())
    with open(tok_file, "w", encoding="utf-8") as f:
        f.write(tok)
else:
    with open(tok_file, "r", encoding="utf-8") as f:
        tok = f.read().strip()
env["MTC_CLUSTER_TOKEN"] = tok

log_p_out = open(os.path.join(REPO, "hub_primary.stdout.log"), "a", encoding="utf-8")
log_p_err = open(os.path.join(REPO, "hub_primary.stderr.log"), "a", encoding="utf-8")
log_s_out = open(os.path.join(REPO, "hub_standby.stdout.log"), "a", encoding="utf-8")
log_s_err = open(os.path.join(REPO, "hub_standby.stderr.log"), "a", encoding="utf-8")

CREATE_NEW_CONSOLE = 0x00000010

# Launch Primary
p_primary = subprocess.Popen(
    [
        BIN,
        "--port", "6000",
        "--http", "0.0.0.0:6010",
        "--role", "primary",
        "--peer-api", "http://127.0.0.1:6011",
        "--peer-zmq", "tcp://127.0.0.1:6001",
    ],
    cwd=REPO,
    env=env,
    stdout=log_p_out,
    stderr=log_p_err,
    creationflags=CREATE_NEW_CONSOLE if sys.platform == "win32" else 0,
)

time.sleep(2)

# Launch Standby
p_standby = subprocess.Popen(
    [
        BIN,
        "--port", "6001",
        "--http", "0.0.0.0:6011",
        "--role", "standby",
        "--peer-api", "http://127.0.0.1:6010",
        "--peer-zmq", "tcp://127.0.0.1:6000",
        "--cluster-state", r"standby_data\cluster_state.json",
        "--config", r"standby_data\config_revisions.jsonl",
        "--commands", r"standby_data\commands.jsonl",
        "--users", r"standby_data\users.json",
        "--notifications", r"standby_data\alert_channels.json",
        "--curve-clients", r"standby_data\curve_clients.txt",
        "--curve-keys", "curve_hub.keys",
        "--audit", r"standby_data\audit.jsonl",
    ],
    cwd=REPO,
    env=env,
    stdout=log_s_out,
    stderr=log_s_err,
    creationflags=CREATE_NEW_CONSOLE if sys.platform == "win32" else 0,
)

time.sleep(1)
print(f"[OK] Primary running (PID {p_primary.pid}) on http://0.0.0.0:6010")
print(f"[OK] Standby running (PID {p_standby.pid}) on http://0.0.0.0:6011")
