#!/usr/bin/env bash
# Build native macOS app extensions from the same SwiftPM library and decoders.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$1"
CONTENTS="$2"
OUT="$CONTENTS/PlugIns"
mkdir -p "$OUT"
for KIND in Thumbnail Preview; do
    EXTENSION="$OUT/Sumra$KIND.appex/Contents"
    mkdir -p "$EXTENSION/MacOS"
    xcrun swiftc -target arm64-apple-macos13.0 -application-extension -emit-executable \
        -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -dead_strip \
        -Xlinker -all_load "$BIN/libSumraQuickLook.a" -larchive \
        -Xlinker -needed_library -Xlinker "$PWD/build/engines/MuPDF.dylib" \
        -Xlinker -rpath -Xlinker @executable_path/../../../../Frameworks \
        -o "$EXTENSION/MacOS/SumraQuickLook"
done
