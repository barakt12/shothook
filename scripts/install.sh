#!/usr/bin/env bash
# Builds, installs to /Applications (override with SHOTHOOK_INSTALL_DIR), and (re)launches.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${SHOTHOOK_INSTALL_DIR:-/Applications}"

scripts/build-app.sh
pkill -x Shothook 2>/dev/null && sleep 0.3 || true
rm -rf "$DEST/Shothook.app"
cp -R build/Shothook.app "$DEST/"
open "$DEST/Shothook.app"
echo "installed $DEST/Shothook.app"
