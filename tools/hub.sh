#!/usr/bin/env bash
# ---------------------------------------------------------------------
# hub.sh - run tools/hub_proto.py from Git Bash / WSL / any POSIX shell.
#
#   ./tools/hub.sh
#   ./tools/hub.sh --port 6100
#   ./tools/hub.sh --verbose
#
# Arguments pass straight through to hub_proto.py.
#
# Finds Python the same way sniff.sh does, so the two tools fail the same
# way when Python is missing rather than each inventing its own message.
#
# This is the Phase 1 PROTOTYPE hub - pure forwarding, no config, no
# registry. It runs until you press Ctrl-C.
# ---------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY=""
for c in python3 python \
         "$HOME/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe" \
         "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe"; do
  command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }
  [[ -x "$c" ]] && { PY="$c"; break; }
done

if [[ -z "$PY" ]]; then
  echo "cannot find python - install it, or run:"
  echo "  <full path to python> $HERE/hub_proto.py --port 6000"
  exit 1
fi

if ! "$PY" -c "import zmq" >/dev/null 2>&1; then
  echo "pyzmq is missing - installing it once, please wait..."
  "$PY" -m pip install --quiet --disable-pip-version-check pyzmq || {
    echo "could not install pyzmq; run: $PY -m pip install pyzmq"
    exit 1
  }
fi

echo
echo "  Starting the Phase 1 prototype hub. Press Ctrl-C to stop it."
echo "  Nothing here is persisted - it just forwards what it receives."
echo

exec "$PY" "$HERE/hub_proto.py" "$@"
