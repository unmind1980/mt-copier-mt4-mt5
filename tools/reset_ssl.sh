#!/usr/bin/env bash
# ===================================================
#   MT-Copier Central Hub - SSL/TLS Emergency Reset
# ===================================================
set -euo pipefail

CFG="tls_config.json"

if [[ ! -f "$CFG" ]]; then
    echo "[INFO] $CFG not found. Hub is already running in default HTTP mode."
    exit 0
fi

echo "[1/3] Backing up current configuration to $CFG.bak ..."
cp -f "$CFG" "$CFG.bak"

echo "[2/3] Disabling TLS/HTTPS in $CFG ..."
sed -i 's/"enabled"[[:space:]]*:[[:space:]]*true/"enabled": false/g' "$CFG"

echo "[3/3] Verification:"
grep -E '"enabled"[[:space:]]*:' "$CFG" || true

echo
echo "==================================================="
echo "[SUCCESS] TLS/HTTPS has been disabled."
echo "Hub will now accept unencrypted HTTP on its port."
echo "If hub is running, restart it to apply the reset."
echo "==================================================="
