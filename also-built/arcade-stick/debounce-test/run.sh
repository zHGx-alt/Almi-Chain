#!/usr/bin/env bash
# Builds the real firmware on the PC with Arduino stand-ins and tests the debounce.
# Usage: bash also-built/arcade-stick/debounce-test/run.sh
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
g++ -std=c++17 -Wall -Wno-unused-function -x c++ -I stubs -o "$out/test" test.cpp
"$out/test"
