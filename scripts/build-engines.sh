#!/usr/bin/env bash
# macOS only. These are decoder libraries, never bundled command-line applications.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "Native macOS engines need the macOS SDK." >&2; exit 1; }
ROOT="$PWD"; OUT="$ROOT/build/engines"; MU="$ROOT/build/deps/mupdf"
REV=f030eda1e472268667805f438e38cee8f1da61f8
mkdir -p "$OUT" "$ROOT/build/deps"
# Corresponding-source archives retain patched sources and their pinned revision,
# without repository metadata. Build those bytes directly instead of checking
# out over the populated exported tree.
EXPORTED_MUPDF=false
if [ ! -e "$MU/.git" ] && [ -f "$MU/.sumra-source-revision" ]; then
    [ "$(cat "$MU/.sumra-source-revision")" = "$REV" ] || { echo "Unexpected exported MuPDF revision." >&2; exit 1; }
    EXPORTED_MUPDF=true
else
    if [ ! -d "$MU/.git" ]; then git init -q "$MU"; git -C "$MU" remote add origin https://github.com/ArtifexSoftware/mupdf.git; fi
    if ! git -C "$MU" cat-file -e "$REV^{commit}" 2>/dev/null; then git -C "$MU" fetch --depth 1 origin "$REV"; fi
    git -C "$MU" checkout -q --detach "$REV"
fi
python3 "$ROOT/scripts/apply-mupdf-patches.py" "$MU" "$ROOT/Native/mupdf-link-coordinates.patch" "$ROOT/Native/mupdf-signature-errors.patch" "$ROOT/Native/mupdf-snapshot.patch" "$ROOT/Native/mupdf-journal-resources.patch" "$ROOT/Native/mupdf-choice-display.patch" "$ROOT/Native/mupdf-script-buttons.patch" "$ROOT/Native/mupdf-form-reset.patch" "$ROOT/Native/mupdf-html-source.patch" "$ROOT/Native/mupdf-html-links.patch" "$ROOT/Native/mupdf-html-image-size.patch" "$ROOT/Native/mupdf-html-structure.patch" "$ROOT/Native/mupdf-html-draw-index.patch" "$ROOT/Native/mupdf-html-outline-targets.patch" "$ROOT/Native/mupdf-pool-total-size.patch" "$ROOT/Native/mupdf-markdown-length.patch" "$ROOT/Native/mupdf-markdown-plugins.patch" "$ROOT/Native/mupdf-markdown-html.patch" "$ROOT/Native/mupdf-epub-direction.patch" "$ROOT/Native/mupdf-selection-map.patch" "$ROOT/Native/mupdf-search-units.patch" "$ROOT/Native/mupdf-info-output.patch" "$ROOT/Native/mupdf-jpegxr-alpha.patch" "$ROOT/Native/mupdf-epub-fixed-layout.patch" "$ROOT/Native/mupdf-html-source-anchors.patch" "$ROOT/Native/mupdf-font-subset.patch" "$ROOT/Native/mupdf-html-selection-text.patch" "$ROOT/Native/mupdf-html-search-separators.patch" "$ROOT/Native/mupdf-search-ligature-geometry.patch" "$ROOT/Native/mupdf-html-document-search.patch" "$ROOT/Native/mupdf-html-source-block-separators.patch" "$ROOT/Native/mupdf-search-chunker-emission.patch" "$ROOT/Native/mupdf-html-search-start.patch" "$ROOT/Native/mupdf-html-layout-performance.patch" "$ROOT/Native/mupdf-markdown-release.patch" "$ROOT/Native/mupdf-reader-fonts.patch" "$ROOT/Native/mupdf-html-compact-spaces.patch" "$ROOT/Native/mupdf-font-resource-face.patch" "$ROOT/Native/mupdf-html-flow-handles.patch" "$ROOT/Native/mupdf-appearance-cjk.patch" "$ROOT/Native/mupdf-font-to-unicode.patch" "$ROOT/Native/mupdf-html-flow-chunk-size.patch"
if [ "$EXPORTED_MUPDF" = false ]; then git -C "$MU" submodule update --init --recursive --depth 1; fi
for patch in "$ROOT/Native/cmark-heading-anchor.patch" "$ROOT/Native/cmark-heading-utf8.patch" "$ROOT/Native/cmark-inline-state.patch"; do
    if ! git -C "$MU/thirdparty/cmark-gfm" apply --reverse --check "$patch" 2>/dev/null; then
        git -C "$MU/thirdparty/cmark-gfm" apply "$patch"
    fi
done
# MuPDF's optional JPEG XR decoder uses the Artifex reference backend.
# It is not a MuPDF submodule; keep its matching source explicitly pinned.
JXR="$MU/thirdparty/jpegxr"
JXR_REV=71ff24a9eb9a5c8dd70e1fd97a5316e06b0b0791
if [ ! -e "$JXR/.git" ] && [ -f "$JXR/.sumra-source-revision" ]; then
    [ "$(cat "$JXR/.sumra-source-revision")" = "$JXR_REV" ] || { echo "Unexpected exported JPEG XR revision." >&2; exit 1; }
else
    if [ ! -d "$JXR/.git" ]; then git init -q "$JXR"; git -C "$JXR" remote add origin https://github.com/ArtifexSoftware/thirdparty-jpegxr.git; fi
    if ! git -C "$JXR" cat-file -e "$JXR_REV^{commit}" 2>/dev/null; then git -C "$JXR" fetch --depth 1 origin "$JXR_REV"; fi
    git -C "$JXR" checkout -q --detach "$JXR_REV"
fi
if ! git -C "$JXR" apply --reverse --check "$ROOT/Native/jpegxr-container.patch" 2>/dev/null; then
    git -C "$JXR" apply "$ROOT/Native/jpegxr-container.patch"
fi
FLAGS=(-Os -fPIC -fvisibility=hidden -mmacosx-version-min=13.0)
# Public CMS/TS decoders supply signature metadata that Security does not expose.
# Security remains the signing/verifying owner; do not build a second verifier,
# TLS library, openssl executable, or loadable provider modules.
DEPS="$ROOT/build/deps"
DOWNLOAD="$(mktemp -d "$DEPS/.crypto-download.XXXXXX")"
trap 'rm -rf "$DOWNLOAD"' EXIT
source "$ROOT/scripts/source-archive.sh"
source_archive openssl-3.5.9 https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a 1
CRYPTO="$DEPS/openssl-3.5.9"
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported macOS architecture: $ARCH" >&2; exit 1;; esac
CRYPTO_BUILD="$ROOT/build/native-macos13/openssl-3.5.9-$ARCH"
mkdir -p "$CRYPTO_BUILD"
(
    cd "$CRYPTO_BUILD"
    "$CRYPTO/Configure" "darwin64-$ARCH" no-shared no-module no-engine no-legacy no-apps no-tests no-docs \
        no-dso no-autoload-config CFLAGS="${FLAGS[*]}"
    make -j"$(sysctl -n hw.logicalcpu)" build_generated
    make -j"$(sysctl -n hw.logicalcpu)" libcrypto.a
)
# SyncTeX is a small parser library, not a TeX distribution or command-line tool.
# Keep only the required pinned sources; normalize their upstream CRLF for the patch.
SYNC_REV=012d997f6a3a5c5c97b878e1a340db3bffde8c0e
STX="$ROOT/build/deps/synctex-$SYNC_REV"
mkdir -p "$STX"
for file in synctex_parser.c synctex_parser_utils.c synctex_parser.h synctex_parser_advanced.h synctex_parser_utils.h synctex_version.h LICENSE; do
    if [ ! -s "$STX/$file" ]; then
        if ! curl --fail --location --silent --show-error "https://raw.githubusercontent.com/sumatrapdfreader/sumatrapdf/$SYNC_REV/ext/synctex/$file" | tr -d '\r' > "$STX/$file"; then
            rm -f "$STX/$file"
            exit 1
        fi
    fi
done
if ! git -C "$STX" apply --reverse --check "$ROOT/Native/synctex-reader.patch" 2>/dev/null; then
    git -C "$STX" apply "$ROOT/Native/synctex-reader.patch"
fi
cc "${FLAGS[@]}" -DSYNCTEX_NO_UPDATER -I"$STX" -c "$STX/synctex_parser.c" -o "$OUT/SyncTeXParser.o"
cc "${FLAGS[@]}" -DSYNCTEX_NO_UPDATER -I"$STX" -c "$STX/synctex_parser_utils.c" -o "$OUT/SyncTeXUtils.o"
cc "${FLAGS[@]}" -I"$STX" -c Native/SyncTeX.c -o "$OUT/SyncTeX.o"
# Follow Sumatra: MuPDF owns fixed/reflowable books; cmark + WebKit owns Markdown/HTML.
# PDF reading, editing and saving share the existing MuPDF owner.
# Existing MuJS supplies PDF form calculations and validation; no second JS runtime.
# Keep OCR/office-export/barcode omitted.
# Sumatra reader font set: installed macOS script fonts plus compact bundled fallback.
FEATURES='-DFZ_ENABLE_PDF=1 -DFZ_ENABLE_OCR_OUTPUT=0 -DFZ_ENABLE_ODT_OUTPUT=0 -DTOFU_CJK_LANG -DSUMRA_READER_FONTS'
make -C "$MU" -j"$(sysctl -n hw.logicalcpu)" libs build=small OUT="$ROOT/build/mupdf" \
    mujs=yes extract=no tesseract=no barcode=no HAVE_LIBCRYPTO=no HAVE_JPEGXR=yes \
    XCFLAGS="${FLAGS[*]} $FEATURES"
cc "${FLAGS[@]}" -I"$MU/include" -I"$MU/thirdparty/freetype/include" -c Native/MuPDF.c -o "$OUT/MuPDF.o"
cc "${FLAGS[@]}" -DCMARK_GFM_STATIC_DEFINE -I"$MU/include" -I"$MU/thirdparty/cmark-gfm/src" -I"$MU/thirdparty/cmark-gfm/extensions" -I"$MU/scripts/cmark-gfm" -c Native/Markdown.c -o "$OUT/Markdown.o"
cc "${FLAGS[@]}" -I"$MU/include" -I"$MU/source" -I"$CRYPTO_BUILD/include" -I"$CRYPTO/include" -c Native/PDFTools.c -o "$OUT/PDFTools.o"
cc "${FLAGS[@]}" -I"$MU/include" -I"$MU/source" -c Native/PDFInfo.c -o "$OUT/PDFInfo.o"
cc "${FLAGS[@]}" -I"$MU/include" -c Native/PDFColors.c -o "$OUT/PDFColors.o"
c++ -dynamiclib -Wl,-dead_strip -mmacosx-version-min=13.0 "$OUT/MuPDF.o" "$OUT/Markdown.o" "$OUT/PDFTools.o" "$OUT/PDFInfo.o" "$OUT/PDFColors.o" "$OUT/SyncTeXParser.o" "$OUT/SyncTeXUtils.o" "$OUT/SyncTeX.o" \
    "$ROOT/build/mupdf/libmupdf.a" "$ROOT/build/mupdf/libmupdf-third.a" "$CRYPTO_BUILD/libcrypto.a" \
    -lm -lpthread -lz -framework Security -framework CoreFoundation -framework CoreText -o "$OUT/MuPDF.dylib"
install_name_tool -id @rpath/MuPDF.dylib "$OUT/MuPDF.dylib"
strip -x "$OUT/MuPDF.dylib"
./scripts/build-codecs.sh
echo "Built four on-demand engines."
