#!/usr/bin/env bash
# ---------------------------------------------------------------------
# fetch-deps.sh - download mql-zmq (ZeroMQ binding for MQL) into
#                 third_party/ and show what it provides.
#
# mql-zmq ships precompiled libzmq DLLs:
#   Library/MT4  -> 32-bit  (MetaTrader 4)
#   Library/MT5  -> 64-bit  (MetaTrader 5)
#
# Since the binding's 2.0.0 release that is libzmq 4.3.5, built with
# MinGW-w64 (GCC) and with libsodium 1.0.22 linked statically into
# libzmq.dll. There is therefore NO libsodium.dll to ship any more, and
# no Visual C++ runtime requirement.
#
# If you would rather not trust prebuilt binaries, build libzmq and
# libsodium yourself and drop the DLLs into the same folders - the
# binding only needs zmq_* and the z85/curve entry points.
# ---------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO/third_party"
URL="https://github.com/dingmaotu/mql-zmq/archive/refs/heads/master.zip"

mkdir -p "$DEST"
cd "$DEST"

if [[ -d mql-zmq-master ]]; then
  echo "mql-zmq already present in $DEST/mql-zmq-master"
else
  echo "downloading $URL"
  if command -v curl >/dev/null 2>&1; then
    curl -sSL -o mql-zmq.zip "$URL"
  elif command -v python >/dev/null 2>&1; then
    python -c "import urllib.request,sys;open('mql-zmq.zip','wb').write(urllib.request.urlopen(sys.argv[1],timeout=120).read())" "$URL"
  else
    echo "need curl or python to download" >&2; exit 1
  fi
  python -c "import zipfile;zipfile.ZipFile('mql-zmq.zip').extractall('.')" 2>/dev/null \
    || unzip -q mql-zmq.zip
  rm -f mql-zmq.zip
fi

echo
echo "headers : $(ls mql-zmq-master/Include/Zmq/*.mqh | wc -l) files in Include/Zmq"
echo "MT4 dlls: $(ls mql-zmq-master/Library/MT4)"
echo "MT5 dlls: $(ls mql-zmq-master/Library/MT5)"
echo
echo "Next: ./tools/deploy.sh"
