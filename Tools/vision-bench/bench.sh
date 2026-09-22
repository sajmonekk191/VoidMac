#!/bin/sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
sources=$here/../../Sources/VoidMac
build=${TMPDIR:-/tmp}/vision-bench
mkdir -p "$build"
find "$sources" -name '*.swift' ! -name main.swift > "$build/sources.txt"
swiftc -Ounchecked -wmo -module-name VoidMacBench "$here/main.swift" @"$build/sources.txt" -o "$build/bench"
VOIDMAC_LOG="$build/bench.log" exec "$build/bench" --fixtures "$here/../hud-regression-check/fixtures" "$@"
