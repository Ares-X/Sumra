#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "The .app requires the macOS SDK; swift test works on Linux." >&2; exit 1; }
CORE=""; BUILD_CONFIGURATION=debug
for option in "$@"; do
    case "$option" in
        --core) CORE=--core ;;
        --release) BUILD_CONFIGURATION=release ;;
        *) echo "Usage: $0 [--core] [--release]" >&2; exit 1 ;;
    esac
done
# Full builds compile native engines; CHM renderer modules are vendored in Resources.
if [ "$CORE" != --core ]; then
    ./scripts/build-engines.sh
fi
# Run the unified checks separately with scripts/check-source.sh.
BUILD_FLAGS=(-c "$BUILD_CONFIGURATION")
if [ "$BUILD_CONFIGURATION" = release ]; then BUILD_FLAGS+=(-Xswiftc -Osize -Xlinker -dead_strip); fi
swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
mkdir -p "$PWD/dist"
APP_STAGE="$(mktemp -d "$PWD/dist/.Sumra-build.XXXXXX")"
APP="$APP_STAGE/Sumra.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/Sumra-icon.XXXXXX")"
cleanup() {
    local result=$?
    rm -rf "$ICON_TMP"
    if [ -d "$APP_STAGE" ]; then
        echo "Retained packaging staging at $APP_STAGE" >&2
    fi
    exit "$result"
}
trap cleanup EXIT
for variant in Light Dark; do
    ICONSET="$ICON_TMP/Sumra-$variant.iconset"
    swift scripts/rasterize-icon.swift "Assets/AppIcon/Sumra-$variant.pdf" "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$APP/Resources/Sumra-$variant.icns"
done
cp "$BIN/Sumra" "$APP/MacOS/Sumra"
if [ "$BUILD_CONFIGURATION" = release ]; then strip -x "$APP/MacOS/Sumra"; fi
# Keep one resource copy. BrowserReader uses this path in an app, Bundle.module in swift run.
cp -R Sources/Sumra/Resources/Reader "$APP/Resources/Reader"
cp -R Sources/Sumra/Resources/Localizations "$APP/Resources/Localizations"
if [ "$CORE" != --core ]; then mkdir -p "$APP/Resources/Tools"; cp build/native-macos13/bin/clit "$APP/Resources/Tools/clit"; chmod 755 "$APP/Resources/Tools/clit"; fi
python3 scripts/bundle.py "$APP" ${CORE:+"$CORE"}
codesign --verify --deep --strict "$APP/.."
# Publish only a completely packaged and verified bundle. Keep the preceding
# app recoverable, including if promotion fails after moving it out of the way.
PREVIOUS=""
if [ -e "$PWD/dist/Sumra.app" ]; then
    PREVIOUS="$(mktemp -d "$PWD/dist/.Sumra-previous.XXXXXX")"
    mv "$PWD/dist/Sumra.app" "$PREVIOUS/Sumra.app"
fi
if ! mv "$APP_STAGE/Sumra.app" "$PWD/dist/Sumra.app"; then
    if [ -n "$PREVIOUS" ]; then mv "$PREVIOUS/Sumra.app" "$PWD/dist/Sumra.app"; rmdir "$PREVIOUS"; fi
    exit 1
fi
rmdir "$APP_STAGE"
if [ -n "$PREVIOUS" ]; then echo "Previous bundle retained at $PREVIOUS/Sumra.app"; fi
if [ "${SUMRA_CODE_SIGN_IDENTITY:--}" = - ]; then
    echo "Built dist/Sumra.app ($BUILD_CONFIGURATION, ad-hoc signed local development build, not notarized)."
else
    echo "Built dist/Sumra.app ($BUILD_CONFIGURATION, signed; notarization and update delivery still require validation)."
fi
du -sh dist/Sumra.app
