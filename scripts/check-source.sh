#!/usr/bin/env bash
# Local checks only. No download, GitHub Actions, signing or publishing.
set -euo pipefail
cd "$(dirname "$0")/.."

# Linux can parse macOS-only branches too; this is NOT macOS SDK type checking.
for source in Sources/Sumra/*.swift; do
    swiftc -frontend -parse -target arm64-apple-macosx13.0 "$source"
done
swift test
# Packaging exercises macOS libarchive, ditto and app metadata.
if [ "$(uname -s)" = Darwin ]; then Tests/Packaging/run-tests.sh; fi

# Optional syntax checks only; browser behavior belongs to the macOS integration pass.
if command -v node >/dev/null; then
    for source in markdown.js chm.js sumatra-find.js; do
        node --input-type=module --check < "Sources/Sumra/Resources/Reader/$source"
    done
fi
