#!/usr/bin/env bash
# Private macOS 13 decoders. Do not link Homebrew bottles built for newer macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; DEPS="$ROOT/build/deps"; BUILD="$ROOT/build/native-macos13"; OUT="$ROOT/build/engines"
MU="$DEPS/mupdf"
export MACOSX_DEPLOYMENT_TARGET=13.0
FLAGS=(-Os -fPIC -fvisibility=hidden -mmacosx-version-min=13.0)
JOBS="$(sysctl -n hw.logicalcpu)"
command -v cmake >/dev/null || { echo "Install build tool: brew install cmake" >&2; exit 1; }
test -f "$ROOT/build/mupdf/libmupdf-third.a" || { echo "Build MuPDF first with scripts/build-engines.sh." >&2; exit 1; }
mkdir -p "$DEPS" "$BUILD" "$OUT"
DOWNLOAD="$(mktemp -d "$DEPS/.codec-download.XXXXXX")"
trap 'rm -rf "$DOWNLOAD"' EXIT

source "$ROOT/scripts/source-archive.sh"

# Gentoo serves the original release bytes; hashes match upstream/Homebrew.
source_archive djvulibre-3.5.30 https://distfiles.gentoo.org/distfiles/be/djvulibre-3.5.30.tar.gz ee5e457d4cfebe566f94b99e5e3d3cc7f5c79ddb741c2ac2ba2e456f00329644 1
source_archive chmlib-0.40 https://web.archive.org/web/20260414144043id_/https://www.jedrea.com/chmlib/chmlib-0.40.tar.gz 512148ed1ca86dea051ebcf62e6debbb00edfdd9720cde28f6ed98071d3a9617 1
source_archive libjxl-0.12.0 https://codeload.github.com/libjxl/libjxl/tar.gz/refs/tags/v0.12.0 03e9be69a30be4011f559da75328b6d7cea8ad921fabfbd551ce10bf45cdc992 1
source_archive highway-457c891775a7397bdb0376bb1031e6e027af1c48 https://codeload.github.com/google/highway/tar.gz/457c891775a7397bdb0376bb1031e6e027af1c48 5124b0501c98d9930dbb065bfa1a5bbbd59ce0f12facb7e1e33aaef01a5f1f1a 1
# Gitiles regenerates different archive bytes for this same commit. Fetch the
# fixed commit from Google's official mirror, as with MuPDF's pinned sources.
SKCMS_REV=96d9171c94b937a1b5f0293de7309ac16311b722
SKCMS="$DEPS/skcms-$SKCMS_REV"
if [ ! -e "$SKCMS/.git" ] && [ -f "$SKCMS/.sumra-source-revision" ]; then
    [ "$(cat "$SKCMS/.sumra-source-revision")" = "$SKCMS_REV" ] || { echo "Unexpected exported skcms revision." >&2; exit 1; }
else
    if [ ! -d "$SKCMS/.git" ]; then git init -q "$SKCMS"; git -C "$SKCMS" remote add origin https://github.com/google/skcms.git; fi
    if ! git -C "$SKCMS" cat-file -e "$SKCMS_REV^{commit}" 2>/dev/null; then git -C "$SKCMS" fetch --depth 1 origin "$SKCMS_REV"; fi
    git -C "$SKCMS" checkout -q --detach "$SKCMS_REV"
fi
source_archive convertlit-1.8 https://distfiles.gentoo.org/distfiles/d0/clit18src.zip d70a85f5b945104340d56f48ec17bcf544e3bb3c35b1b3d58d230be699e557ba 0
source_archive libtommath-1.3.0 https://github.com/libtom/libtommath/releases/download/v1.3.0/ltm-1.3.0.tar.xz 296272d93435991308eb73607600c034b558807a07e829e751142e65ccfa9d08 1
DJVU="$DEPS/djvulibre-3.5.30"; CHM="$DEPS/chmlib-0.40"; JXL="$DEPS/libjxl-0.12.0"

# Use MuPDF's matching IJG headers/archive, with IJG's standalone allocator.
# MuPDF normally supplies its own allocator; no MuPDF document code is linked here.
mkdir -p "$BUILD/djvu"
JPEG_CFLAGS="-I$MU/thirdparty/libjpeg -I$MU/scripts/libjpeg"
cc "${FLAGS[@]}" -I"$MU/thirdparty/libjpeg" -I"$MU/scripts/libjpeg" -c "$MU/thirdparty/libjpeg/jmemnobs.c" -o "$BUILD/djvu/jpeg-memory.o"
(
    cd "$BUILD/djvu"
    CFLAGS="${FLAGS[*]}" CXXFLAGS="${FLAGS[*]} -fvisibility-inlines-hidden" LDFLAGS=-mmacosx-version-min=13.0 \
        JPEG_CFLAGS="$JPEG_CFLAGS" JPEG_LIBS="$BUILD/djvu/jpeg-memory.o $ROOT/build/mupdf/libmupdf-third.a" \
        "$DJVU/configure" --prefix="$BUILD" --disable-shared --enable-static --disable-desktopfiles --disable-xmltools --without-tiff
    grep -q '^#define HAVE_JPEG 1' config.h || { echo "DjVu JPEG support is required." >&2; exit 1; }
    # Keep the static DjVu archive separate; its JPEG objects are selected at final link.
    make -C libdjvu -j"$JOBS" CXXFLAGS="${FLAGS[*]} -fvisibility-inlines-hidden" JPEG_LIBS=
)
cc "${FLAGS[@]}" -I"$DJVU" -c Native/DjVu.c -o "$BUILD/DjVu.o"
c++ -dynamiclib -Wl,-dead_strip '-Wl,-exported_symbol,_lf_*' -mmacosx-version-min=13.0 \
    "$BUILD/DjVu.o" "$BUILD/djvu/libdjvu/.libs/libdjvulibre.a" "$BUILD/djvu/jpeg-memory.o" "$ROOT/build/mupdf/libmupdf-third.a" \
    -framework CoreGraphics -framework CoreFoundation -o "$BUILD/DjVu.dylib"

# CHMLib needs only these two source files. Retain its existing pthread/pread path
# and the upstream/Homebrew arm64 sized-integer correction, without its old libtool.
sed 's/#elif __x86_64__ || __ia64__/#elif __x86_64__ || __ia64__ || __aarch64__/' "$CHM/src/chm_lib.c" > "$BUILD/chm_lib.c"
cc "${FLAGS[@]}" -DCHM_MT -DCHM_USE_PREAD -I"$CHM/src" -dynamiclib -Wl,-dead_strip '-Wl,-exported_symbol,_lf_*' \
    Native/CHM.c "$BUILD/chm_lib.c" "$CHM/src/lzx.c" -o "$BUILD/CHM.dylib"

# Source subdirectories in the release archive are empty placeholders. Reuse the
# already pinned MuPDF Brotli source; Highway/skcms pins match libjxl's deps.sh.
for pair in "brotli:$MU/thirdparty/brotli" "highway:$DEPS/highway-457c891775a7397bdb0376bb1031e6e027af1c48" "skcms:$DEPS/skcms-96d9171c94b937a1b5f0293de7309ac16311b722"; do
    name="${pair%%:*}"; source="${pair#*:}"
    if [ ! -L "$JXL/third_party/$name" ]; then rmdir "$JXL/third_party/$name"; ln -s "$source" "$JXL/third_party/$name"; fi
done
cmake -S "$JXL" -B "$BUILD/jxl" -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_VERSION=0.12.0
# jxl_dec retains animation, ICC, boxes and JPEG reconstruction, without encoders.
cmake --build "$BUILD/jxl" --target jxl_dec -j"$JOBS"
cc "${FLAGS[@]}" -DJXL_STATIC_DEFINE -I"$JXL/lib/include" -I"$BUILD/jxl/lib/include" -c Native/JPEGXL.c -o "$BUILD/JPEGXL.o"
c++ -dynamiclib -Wl,-dead_strip '-Wl,-exported_symbol,_lf_*' -mmacosx-version-min=13.0 "$BUILD/JPEGXL.o" \
    "$BUILD/jxl/lib/libjxl_dec.a" "$BUILD/jxl/third_party/highway/libhwy.a" \
    "$BUILD/jxl/third_party/brotli/libbrotlidec.a" "$BUILD/jxl/third_party/brotli/libbrotlicommon.a" -o "$BUILD/JPEGXL.dylib"

# ConvertLIT's original makefiles use the old libtommath-0.30 directory name.
# Its API is supplied by pinned libtommath 1.3.0, not a global Homebrew archive.
LTM="$DEPS/libtommath-1.3.0"; CLIT="$DEPS/convertlit-1.8"
make -C "$LTM" -j"$JOBS" libtommath.a CC=cc CFLAGS="${FLAGS[*]}"
if [ ! -L "$CLIT/libtommath-0.30" ]; then ln -s "$LTM" "$CLIT/libtommath-0.30"; fi
# Use the pinned Apache-2.0 tables and restore the original missing declarations;
# suppressing implicit declarations can truncate strlen's result on 64-bit Macs.
swift "$ROOT/scripts/setup-convertlit.swift" "$CLIT" "$ROOT/Native/convertlit-des-spr.h"
make -C "$CLIT/lib" -j"$JOBS" CC=cc CFLAGS="${FLAGS[*]} -Werror=implicit-function-declaration -Ides -Isha -Inewlzx -I."
# Test the actual object selected for the helper, including legacy block outputs.
cc "${FLAGS[@]}" -I"$CLIT/lib/des" Tests/Native/ConvertLITBlockTests.c \
    "$CLIT/lib/des/des.o" -o "$DOWNLOAD/convertlit-block-tests"
"$DOWNLOAD/convertlit-block-tests"
make -C "$CLIT/clit18" -j"$JOBS" CC=cc CFLAGS="${FLAGS[*]} -funsigned-char -Werror=implicit-function-declaration -I$LTM -I../lib -I../lib/des -I."
mkdir -p "$BUILD/bin"
cp "$CLIT/clit18/clit" "$BUILD/bin/clit"
strip -x "$BUILD/bin/clit"
for name in DjVu CHM JPEGXL; do
    install_name_tool -id "@rpath/$name.dylib" "$BUILD/$name.dylib"
    strip -x "$BUILD/$name.dylib"
    mv "$BUILD/$name.dylib" "$OUT/$name.dylib"
done
# Keep verified inputs and final outputs, not a second cache of decoder objects.
make -C "$LTM" clean >/dev/null
make -C "$CLIT/lib" clean >/dev/null
make -C "$CLIT/clit18" clean >/dev/null
rm -f "$CLIT/lib/newlzx/lzxglue.o" "$CLIT/lib/newlzx/lzxd.o"
rm -rf "$BUILD/djvu" "$BUILD/jxl"
rm -f "$BUILD/DjVu.o" "$BUILD/JPEGXL.o" "$BUILD/chm_lib.c"
echo "Built macOS 13 private DjVu, CHM, JPEG XL and ConvertLIT."
