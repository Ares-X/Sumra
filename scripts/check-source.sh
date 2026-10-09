#!/usr/bin/env bash
# Local checks only. No download, GitHub Actions, signing or publishing.
set -euo pipefail
cd "$(dirname "$0")/.."

# Linux can parse macOS-only branches too; this is NOT macOS SDK type checking.
for source in Sources/Sumra/*.swift; do
    swiftc -frontend -parse -target arm64-apple-macosx13.0 "$source"
done
swift test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Packaging -p 'test_*.py'

# Optional syntax checks only; browser behavior belongs to the macOS integration pass.
if command -v node >/dev/null; then
    for source in markdown.js chm.js sumatra-find.js; do
        node --input-type=module --check < "Sources/Sumra/Resources/Reader/$source"
    done
fi
