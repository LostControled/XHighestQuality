#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios15.0"
MODULE_CACHE="$PWD/.modulecache"

echo "==> compiling"
clang -target "$TARGET" \
  -isysroot "$SDK" \
  -fobjc-arc \
  -fmodules-cache-path="$MODULE_CACHE" \
  -O2 -Wall -Wextra \
  -c XHighestQuality.m \
  -o XHighestQuality.o

echo "==> linking"
clang -target "$TARGET" \
  -isysroot "$SDK" \
  -fobjc-arc \
  -fmodules-cache-path="$MODULE_CACHE" \
  -O2 \
  -dynamiclib XHighestQuality.o \
  -o XHighestQuality.dylib \
  -framework Foundation \
  -framework AVFoundation \
  -framework CoreGraphics \
  -install_name @executable_path/Frameworks/XHighestQuality.dylib

echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none XHighestQuality.dylib

echo "==> result"
file XHighestQuality.dylib
codesign -dv XHighestQuality.dylib 2>&1 | sed -n '1,8p'
ls -lh XHighestQuality.dylib
