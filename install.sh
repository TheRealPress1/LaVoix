#!/bin/bash
# Build LaVoix, install to /Applications, relaunch.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
pkill -x LaVoix || true
rm -rf /Applications/LaVoix.app
cp -R DerivedData/Build/Products/Debug/LaVoix.app /Applications/LaVoix.app
open /Applications/LaVoix.app
echo "LaVoix installed."
