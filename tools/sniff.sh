#!/usr/bin/env bash
# ---------------------------------------------------------------------
# sniff.sh - run tools/zmq_sniff.py from Git Bash / WSL / any POSIX shell.
#
#   ./tools/sniff.sh
#   ./tools/sniff.sh --seconds 60
#   ./tools/sniff.sh --host 127.0.0.1 --events 5565
#
# Arguments pass straight through to zmq_sniff.py.
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
  echo "  <full path to python> $HERE/zmq_sniff.py --seconds 30"
  exit 1
fi

if ! "$PY" -c "import zmq" >/dev/null 2>&1; then
  echo "pyzmq is missing - installing it once, please wait..."
  "$PY" -m pip install --quiet --disable-pip-version-check pyzmq || {
    echo "could not install pyzmq; run: $PY -m pip install pyzmq"
    exit 1
  }
fi

exec "$PY" "$HERE/zmq_sniff.py" "$@"
