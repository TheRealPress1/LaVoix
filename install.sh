#!/bin/bash
# Build LaVoix, install to /Applications, relaunch.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
# Never quit LaVoix while a meeting is being recorded (the newest session.json is in a live state and was written in the last 2 minutes).
python3 - <<'PY' || exit 1
import os, json, time, sys
folder = os.path.expanduser("~/Library/Application Support/FluidVoice/Meetings")
newest = None
for name in (os.listdir(folder) if os.path.isdir(folder) else []):
    path = os.path.join(folder, name, "session.json")
    try: mtime = os.path.getmtime(path)
    except OSError: continue
    if newest is None or mtime > newest[0]: newest = (mtime, path)
if newest and time.time() - newest[0] < 120:
    try: state = json.load(open(newest[1])).get("state")
    except Exception: state = None
    if state not in ("completed", "failed", "cancelled", ""):
        print("A meeting is being recorded. Not installing."); sys.exit(1)
PY
pkill -x LaVoix || true
rm -rf /Applications/LaVoix.app
cp -R DerivedData/Build/Products/Debug/LaVoix.app /Applications/LaVoix.app
open /Applications/LaVoix.app
echo "LaVoix installed."
