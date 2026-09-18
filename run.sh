#!/bin/zsh
set -e
cd "$(dirname "$0")"
./make-app.sh
pkill -x VoidMac 2>/dev/null || true
sleep 0.3
open build/VoidMac.app
echo "Void# started (scope icon in the menu bar, panel = Right ⌘)"
