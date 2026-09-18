#!/bin/sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
source=${HUD_SOURCE:-$here/../../Sources/VoidMac/AbilityHud.swift}
build=${TMPDIR:-/tmp}/hud-regression-check
mkdir -p "$build"
cp "$source" "$build/AbilityHud.swift"
cp "$here/main.swift" "$build/main.swift"
swiftc -O "$build/main.swift" "$build/AbilityHud.swift" -o "$build/check"
exec "$build/check" "$here"
