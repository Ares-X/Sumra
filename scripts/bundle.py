#!/usr/bin/env python3
"""Bundle runtime dylibs and generate Info.plist for the local app."""
import plistlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
contents = Path(sys.argv[1]).resolve()
core = "--core" in sys.argv[2:]
frameworks = contents / "Frameworks"
licenses = contents / "Resources" / "Licenses"
frameworks.mkdir(parents=True, exist_ok=True)
licenses.mkdir(parents=True, exist_ok=True)
identity = os.environ.get("SUMRA_CODE_SIGN_IDENTITY", "-")
keychain = os.environ.get("SUMRA_CODE_SIGN_KEYCHAIN", "")
timestamp = os.environ.get("SUMRA_CODE_SIGN_TIMESTAMP", "")
version = os.environ.get("SUMRA_VERSION", "0.2.1")
build_version = os.environ.get("SUMRA_BUILD_VERSION", "3")
updates = json.loads((root / "Assets/Updates.json").read_text())
update_feed = os.environ.get("SUMRA_UPDATE_FEED_URL", updates["feed_url"])
update_key = os.environ.get("SUMRA_UPDATE_PUBLIC_KEY", updates["public_key"])
if bool(update_feed) != bool(update_key):
    raise RuntimeError("Set SUMRA_UPDATE_FEED_URL and SUMRA_UPDATE_PUBLIC_KEY together.")
shutil.copy(root / "LICENSE", licenses / "Sumra-AGPL-3.0.txt")
shutil.copy(root / "THIRD_PARTY.md", licenses / "THIRD_PARTY.md")
for notice in (root / "Licenses").glob("*.txt"):
    shutil.copy(notice, licenses / notice.name)

def run(*args):
    return subprocess.check_output([str(x) for x in args], text=True)

def sign(path, entitlements=None):
    options = []
    if identity != "-":
        options = ["--options", "runtime", f"--timestamp={timestamp}" if timestamp else "--timestamp"]
        if keychain:
            options += ["--keychain", keychain]
        if entitlements:
            options += ["--entitlements", entitlements]
    subprocess.check_call(["codesign", "--force", "--sign", identity, *options, str(path)])

# SwiftPM supplies the pinned binary framework. Ship its runtime and installer
# helpers; development headers/modules and sandbox-only XPC services are unused.
sparkle_sources = list((root / ".build/artifacts/sparkle").glob("*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"))
if len(sparkle_sources) != 1:
    raise RuntimeError("Build the package first to resolve the pinned Sparkle framework.")
sparkle = frameworks / "Sparkle.framework"
shutil.copytree(sparkle_sources[0], sparkle, symlinks=True)
for name in ("Headers", "PrivateHeaders", "Modules", "XPCServices"):
    (sparkle / name).unlink()
    shutil.rmtree(sparkle / "Versions/B" / name)
# Installer helpers must share the app's signing identity, including ad-hoc.
for helper in ("Autoupdate", "Updater.app"):
    sign(sparkle / "Versions/B" / helper)
sign(sparkle)

def macho(source):
    ident = set(run("otool", "-D", source).splitlines()[1:])
    commands = run("otool", "-l", source)
    minimums = re.findall(r"cmd LC_BUILD_VERSION\n\s*cmdsize \d+\n\s*platform \S+\n\s*minos ([\d.]+)", commands)
    minimums += re.findall(r"cmd LC_VERSION_MIN_MACOSX\n\s*cmdsize \d+\n\s*version ([\d.]+)", commands)
    for minimum in minimums:
        if tuple(int(part) for part in minimum.split(".")) > (13, 0, 0):
            raise RuntimeError(f"{source} requires macOS {minimum}, above the app's macOS 13 target. Rebuild this dependency from source.")
    rpaths = re.findall(r"cmd LC_RPATH\n.*?\n\s*path (.+?) \(offset", commands)
    deps = []
    for line in run("otool", "-L", source).splitlines()[1:]:
        dep = line.strip().split(" (compatibility")[0]
        if dep not in ident and not dep.startswith(("/usr/lib/", "/System/Library/")):
            deps.append(dep)
    return rpaths, deps

def resolve(source, dependency, rpaths):
    def expand(value):
        return Path(value.replace("@loader_path", str(source.parent))
                         .replace("@executable_path", str(contents / "MacOS")))
    if dependency.startswith("@rpath/"):
        tail = dependency[len("@rpath/"):]
        return next((expand(path) / tail for path in rpaths if (expand(path) / tail).is_file()), None)
    path = expand(dependency)
    return path if path.is_file() else None

copied = {}
def bundle(source):
    source = Path(source).resolve()
    if source in copied:
        return copied[source]
    target = frameworks / source.name
    if target.exists():
        raise RuntimeError(f"Duplicate dylib name: {source.name}")
    copied[source] = target
    shutil.copy2(source, target)
    target.chmod(0o755)
    rpaths, deps = macho(source)
    for dependency in deps:
        resolved = resolve(source, dependency, rpaths)
        if resolved is None:
            raise RuntimeError(f"Cannot resolve {dependency} from {source}")
        child = bundle(resolved)
        subprocess.check_call(["install_name_tool", "-change", dependency, "@loader_path/" + child.name, str(target)])
    subprocess.check_call(["install_name_tool", "-id", "@rpath/" + target.name, str(target)])
    return target

if not core:
    shutil.copy(root / "build" / "deps" / "synctex-012d997f6a3a5c5c97b878e1a340db3bffde8c0e" / "LICENSE",
                licenses / "SyncTeX-MIT.txt")
    for source, name in (
        ("djvulibre-3.5.30/COPYING", "DjVuLibre-GPL-2.0.txt"),
        ("chmlib-0.40/COPYING", "CHMLib-LGPL-2.1.txt"),
        ("libjxl-0.12.0/LICENSE", "JPEGXL-BSD-3-Clause.txt"),
        ("libjxl-0.12.0/PATENTS", "JPEGXL-PATENTS.txt"),
        ("highway-457c891775a7397bdb0376bb1031e6e027af1c48/LICENSE", "Highway-Apache-2.0.txt"),
        ("highway-457c891775a7397bdb0376bb1031e6e027af1c48/LICENSE-BSD3", "Highway-BSD-3-Clause.txt"),
        ("mupdf/thirdparty/brotli/LICENSE", "Brotli-MIT.txt"),
        ("mupdf/thirdparty/libjpeg/README", "IJG-JPEG.txt"),
        ("mupdf/thirdparty/jpegxr/Software/COPYRIGHT.txt", "JPEGXR-Reference-Copyright.txt"),
        ("mupdf/COPYING", "MuPDF-AGPL-3.0.txt"),
        ("mupdf/thirdparty/cmark-gfm/COPYING", "CMark-GFM.txt"),
        ("mupdf/thirdparty/freetype/LICENSE.TXT", "FreeType-License.txt"),
        ("mupdf/thirdparty/freetype/docs/FTL.TXT", "FreeType-FTL.txt"),
        ("mupdf/thirdparty/harfbuzz/COPYING", "HarfBuzz.txt"),
        ("mupdf/thirdparty/harfbuzz/src/ms-use/COPYING", "HarfBuzz-MS-USE.txt"),
        ("mupdf/thirdparty/gumbo-parser/doc/COPYING", "Gumbo-Apache-2.0.txt"),
        ("mupdf/thirdparty/jbig2dec/COPYING", "JBIG2Dec-AGPL-3.0.txt"),
        ("mupdf/thirdparty/jbig2dec/LICENSE", "JBIG2Dec-Notice.txt"),
        ("mupdf/thirdparty/lcms2/LICENSE", "LittleCMS.txt"),
        ("mupdf/thirdparty/mujs/COPYING", "MuJS-ISC.txt"),
        ("mupdf/thirdparty/openjpeg/LICENSE", "OpenJPEG.txt"),
        ("mupdf/thirdparty/zlib/LICENSE", "Zlib.txt"),
        ("mupdf/resources/fonts/sil/OFL.txt", "Charis-SIL-OFL.txt"),
        ("mupdf/resources/fonts/urw/OFL.txt", "URW-Fonts-OFL.txt"),
        ("mupdf/resources/fonts/han/LICENSE.txt", "Source-Han-Serif-SIL-OFL.txt"),
        ("mupdf/resources/fonts/noto/COPYING", "Noto-Fonts.txt"),
        ("mupdf/resources/fonts/droid/NOTICE", "Droid-Fonts-Notice.txt"),
        ("convertlit-1.8/clit18/COPYING", "ConvertLIT-GPL-2.0.txt"),
        ("libtommath-1.3.0/LICENSE", "LibTomMath-Unlicense.txt"),
    ):
        shutil.copy(root / "build" / "deps" / source, licenses / name)
    for name in ("MuPDF", "DjVu", "CHM", "JPEGXL"):
        source = root / "build" / "engines" / f"{name}.dylib"
        bundle(source)

tool = contents / "Resources" / "Tools" / "clit"
if not core:
    rpaths, deps = macho(tool)
    for dependency in deps:
        resolved = resolve(tool, dependency, rpaths)
        if resolved is None:
            raise RuntimeError(f"Cannot resolve {dependency} from {tool}")
        child = bundle(resolved)
        subprocess.check_call(["install_name_tool", "-change", dependency, "@loader_path/../../Frameworks/" + child.name, str(tool)])
    sign(tool)

groups = re.findall(r'\(\.(\w+),\s*"([^"]+)"\)', (root / "Sources/SumraCore/Format.swift").read_text())
disabled = {"book", "markdown", "html", "mupdf", "djvu", "chm", "lit"} if core else set()
suffixes = [values for kind, values in groups if kind not in disabled]
if core:
    suffixes = [" ".join(x for x in values.split() if x not in {"jxl", "pdb", "p7m"}) for values in suffixes]

# Keep the installed application's identity so preferences, recent documents
# and macOS restoration survive the product rename.
info = dict(
    CFBundleName="Sumra", CFBundleDisplayName="Sumra", CFBundleExecutable="Sumra",
    CFBundleIdentifier="dev.aresx.leaf", CFBundlePackageType="APPL",
    CFBundleShortVersionString=version, CFBundleVersion=build_version,
    CFBundleGetInfoString="Sumra " + version, NSHumanReadableCopyright="© 2026 Sumra contributors",
    LSApplicationCategoryType="public.app-category.productivity",
    LSMinimumSystemVersion="13.0", NSHighResolutionCapable=True,
    CFBundleDocumentTypes=[dict(
        CFBundleTypeName="Readable documents", CFBundleTypeRole="Viewer", LSHandlerRank="Alternate",
        CFBundleTypeExtensions=sorted(set(" ".join(suffixes).split()))
    )],
    LSSupportsOpeningDocumentsInPlace=True, LSMultipleInstancesProhibited=True,
    CFBundleIconFile="Sumra-Light.icns"
)
if update_feed:
    info.update(SUFeedURL=update_feed, SUPublicEDKey=update_key, SUEnableAutomaticChecks=True)
with (contents / "Info.plist").open("wb") as f:
    plistlib.dump(info, f)

for target in copied.values():
    subprocess.check_call(["strip", "-x", str(target)])
    sign(target)
sign(contents.parent, os.environ.get("SUMRA_CODE_SIGN_ENTITLEMENTS"))
print(f"{len(copied)} decoder dylibs bundled.")
