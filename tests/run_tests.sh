#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos14.0"
CACHE="$ROOT/.modulecache-mac"

clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -fmodules-cache-path="$CACHE" \
  -O1 -g -dynamiclib "$ROOT/XHighestQuality.m" \
  -o XHighestQuality_macos.dylib \
  -framework Foundation -framework AVFoundation -framework CoreGraphics \
  -install_name @rpath/XHighestQuality_macos.dylib

clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -fmodules-cache-path="$CACHE" \
  -O0 -g TestHarness.m \
  -o TestHarness \
  -framework Foundation -framework AVFoundation -framework CoreGraphics

./TestHarness ./XHighestQuality_macos.dylib
