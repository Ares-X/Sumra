#!/usr/bin/env python3
"""Inventory and archive the release app and corresponding source; never sign or publish."""
import argparse
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROJECT_FILES = ("LICENSE", "THIRD_PARTY.md", "README.md", "README.zh-CN.md", "Package.swift", "Package.resolved", "AGENTS.md", ".gitignore")
PROJECT_DIRS = ("Sources", "Tests", "Native", "scripts", "Assets", "Licenses", "docs")
SKIP = {".git", ".DS_Store", "__pycache__", ".serena", ".swiftpm"}
PRODUCT_SUFFIXES = {".o", ".a", ".so", ".dylib", ".pyc", ".pyo"}
SYNC_REV = "012d997f6a3a5c5c97b878e1a340db3bffde8c0e"
SYNC_FILES = ("synctex_parser.c", "synctex_parser_utils.c", "synctex_parser.h", "synctex_parser_advanced.h", "synctex_parser_utils.h", "synctex_version.h", "LICENSE")


def git(directory, *args):
    return subprocess.check_output(["git", "-C", str(directory), *args])


def digest(path):
    if isinstance(path, bytes):
        return hashlib.sha256(path).hexdigest()
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def archived_digest(handle):
    value = hashlib.sha256()
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        value.update(block)
    return value.hexdigest()


def verify_source_archive(path, files, symlinks):
    expected = {"Sumra-source/" + name for name in files.keys() | symlinks.keys()}
    seen = set()
    with tarfile.open(path, "r:gz") as archive:
        for entry in archive:
            if entry.name not in expected or entry.name in seen:
                raise RuntimeError(f"Unexpected or duplicate archived source: {entry.name}")
            seen.add(entry.name)
            name = entry.name.removeprefix("Sumra-source/")
            if name in files:
                if not entry.isfile():
                    raise RuntimeError(f"Archived source is not a regular file: {name}")
                if entry.mode != files[name]["mode"]:
                    raise RuntimeError(f"Archived source permissions changed during packaging: {name}")
                with archive.extractfile(entry) as handle:
                    actual = archived_digest(handle)
                if actual != files[name]["sha256"]:
                    raise RuntimeError(f"Archived source changed during packaging: {name}")
            elif not entry.issym() or entry.linkname != symlinks[name]:
                raise RuntimeError(f"Archived source link changed during packaging: {name}")
    if seen != expected:
        raise RuntimeError(f"Missing archived source: {', '.join(sorted(expected - seen))}")


def verify_app_archive(path, app_name, files, symlinks, modes, directories):
    expected_directories = {(app_name + "/" + name).rstrip("/") + "/": mode
                            for name, mode in directories.items()}
    expected = {app_name + "/" + name for name in files.keys() | symlinks.keys()} | expected_directories.keys()
    seen = set()
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            if entry.filename not in expected or entry.filename in seen:
                raise RuntimeError(f"Unexpected or duplicate archived app file: {entry.filename}")
            seen.add(entry.filename)
            name = entry.filename.removeprefix(app_name + "/")
            kind = stat.S_IFMT(entry.external_attr >> 16) if entry.create_system == 3 else 0
            if entry.filename in expected_directories:
                if kind != stat.S_IFDIR or stat.S_IMODE(entry.external_attr >> 16) != expected_directories[entry.filename]:
                    raise RuntimeError(f"Archived app directory changed during packaging: {entry.filename}")
                continue
            if name in files:
                if kind != stat.S_IFREG:
                    raise RuntimeError(f"Archived app is not a regular file: {name}")
                if stat.S_IMODE(entry.external_attr >> 16) != modes[name]:
                    raise RuntimeError(f"Archived app permissions changed during packaging: {name}")
                with archive.open(entry) as handle:
                    actual = archived_digest(handle)
                if actual != files[name]:
                    raise RuntimeError(f"Archived app changed during packaging: {name}")
            elif kind != stat.S_IFLNK or archive.read(entry) != symlinks[name].encode():
                raise RuntimeError(f"Archived app link changed during packaging: {name}")
    if seen != expected:
        raise RuntimeError(f"Missing archived app file: {', '.join(sorted(expected - seen))}")


def archive_app(app, archive):
    # The product inventory covers data forks and POSIX modes, not AppleDouble.
    # Reject real resource data before omitting host metadata from the ZIP.
    for path in sorted(app.rglob("*")):
        if not stat.S_ISREG(path.lstat().st_mode):
            continue
        try:
            with (path / "..namedfork" / "rsrc").open("rb") as resource:
                if resource.read(1):
                    raise RuntimeError(f"Candidate has an unarchived resource fork: {path}")
        except OSError as error:
            if error.errno not in (errno.ENOENT, errno.ENOTDIR):
                raise
    subprocess.run(["ditto", "-c", "-k", "--keepParent", "--norsrc",
                    "--noextattr", "--noacl", "--noqtn", str(app), str(archive)], check=True)


def app_inventory(app):
    result = {"app_files": {}, "app_symlinks": {}, "app_modes": {},
              "app_directories": {"": stat.S_IMODE(app.stat().st_mode)}}
    for path in sorted(app.rglob("*")):
        name = str(path.relative_to(app))
        if path.is_symlink():
            result["app_symlinks"][name] = os.readlink(path)
        elif path.is_file():
            result["app_files"][name] = digest(path)
            result["app_modes"][name] = stat.S_IMODE(path.stat().st_mode)
        elif path.is_dir():
            result["app_directories"][name] = stat.S_IMODE(path.stat().st_mode)
        else:
            raise RuntimeError(f"Unexpected candidate app entry: {path}")
    return result


def app_metadata(app):
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    signature = subprocess.run(["codesign", "--display", "--verbose=4", str(app)], check=True, text=True, capture_output=True)
    # Include public signature facts; omit absolute paths and unneeded output.
    fields = {"Identifier", "Format", "CodeDirectory", "Signature", "Authority", "TeamIdentifier", "Timestamp", "CDHash", "Runtime Version"}
    signing = {}
    for line in signature.stderr.splitlines():
        if line.startswith("CodeDirectory "):
            signing.setdefault("CodeDirectory", []).append(line.removeprefix("CodeDirectory "))
            continue
        key, separator, value = line.partition("=")
        if separator and key in fields:
            signing.setdefault(key, []).append(value)
    return {
        "info_plist": {key: info.get(key) for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks")},
        "architectures": subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/Sumra")], text=True).strip().split(),
        "signature": signing,
        "gatekeeper_public_acceptance": "not_exercised",
    }


def validate_frozen_receipts(source_path, build_path, source_manifest, bundle, metadata):
    source = json.loads(source_path.read_text())
    build = json.loads(build_path.read_text())
    expected_source_fields = ("origins", "files", "symlinks", "project_revision", "source_build_match")
    for key in expected_source_fields:
        if source.get(key) != source_manifest[key]:
            raise RuntimeError(f"Frozen source receipt does not match current allowlisted source: {key}")
    source_hash = digest(source_path)
    if build.get("source_inputs_sha256") != source_hash or build.get("final_source_inputs_sha256") != source_hash:
        raise RuntimeError("Build receipt does not bind to the supplied frozen source receipt")
    if build.get("build_exit") != 0:
        raise RuntimeError("Build receipt reports an unsuccessful build")
    recorded_bundle = build.get("bundle")
    if recorded_bundle != bundle:
        raise RuntimeError("Current app does not match frozen build receipt: bundle inventory")
    if build.get("metadata") != metadata:
        raise RuntimeError("Current app metadata does not match frozen build receipt")
    return {
        "source_receipt_sha256": source_hash,
        "build_receipt_sha256": digest(build_path),
        "source_origins": source["origins"],
        "source_files": source["files"],
        "source_symlinks": source["symlinks"],
        "app_bundle": recorded_bundle,
        "app_metadata": build["metadata"],
        "source_build_match": "matches_frozen_build_receipt",
        "claim_limit": "Receipt correspondence only; not reproducibility, redistribution, or signing proof.",
    }


def inventory():
    files = {}
    origins = []
    git_revisions = {}
    links = []

    def add(path, destination):
        if path.is_symlink():
            links.append((path, destination))
        elif path.is_file():
            files[destination] = path
        else:
            raise RuntimeError(f"Missing source input: {path}")

    def tree(directory, destination, source_archive=False):
        for parent, directories, names in os.walk(directory, followlinks=False):
            directories[:] = sorted(name for name in directories if name not in SKIP)
            for name in list(directories):
                path = Path(parent) / name
                if path.is_symlink():
                    add(path, str(Path(destination) / path.relative_to(directory)))
                    directories.remove(name)
            for name in sorted(names):
                path = Path(parent) / name
                if name in SKIP or path.suffix in PRODUCT_SUFFIXES or (source_archive and name == "clit"):
                    continue
                add(path, str(Path(destination) / path.relative_to(directory)))

    def repository(directory, destination, expected=None):
        revision = git(directory, "rev-parse", "HEAD").decode().strip()
        if expected and revision != expected:
            raise RuntimeError(f"Unexpected source revision: {directory}: {revision}, expected {expected}")
        origins.append({"path": destination, "revision": revision})
        git_revisions[destination] = revision
        for entry in git(directory, "ls-files", "--stage", "-z").split(b"\0"):
            if not entry:
                continue
            metadata, name = entry.decode().split("\t", 1)
            mode, commit, stage = metadata.split()
            if stage != "0":
                raise RuntimeError(f"Unmerged source input: {directory / name}")
            if any(part in SKIP for part in Path(name).parts):
                continue
            if mode == "160000":
                repository(directory / name, str(Path(destination) / name), commit)
            else:
                add(directory / name, str(Path(destination) / name))

    for name in PROJECT_FILES:
        add(ROOT / name, name)
    for name in PROJECT_DIRS:
        tree(ROOT / name, name)
    repository(ROOT / "build/deps/mupdf", "build/deps/mupdf", "f030eda1e472268667805f438e38cee8f1da61f8")
    repository(ROOT / "build/deps/mupdf/thirdparty/jpegxr", "build/deps/mupdf/thirdparty/jpegxr", "71ff24a9eb9a5c8dd70e1fd97a5316e06b0b0791")
    # Adapted Sumatra implementation lives in the project's source; this sparse
    # reference checkout is not a build dependency. SyncTeX is included below.
    pin = next(pin for pin in json.loads((ROOT / "Package.resolved").read_text())["pins"] if pin["identity"] == "sparkle")
    repository(ROOT / ".build/checkouts/Sparkle", "upstream/Sparkle", pin["state"]["revision"])
    origins[-1]["url"] = pin["location"]
    origins[-1]["version"] = pin["state"]["version"]
    for script in ("build-engines.sh", "build-codecs.sh"):
        for name, url, expected, strip in re.findall(r"^source_archive (\S+) (\S+) ([0-9a-f]{64}) (\d+)$", (ROOT / "scripts" / script).read_text(), re.MULTILINE):
            directory = ROOT / "build/deps" / name
            if (directory / ".leaf-source").read_text().strip() != expected:
                raise RuntimeError(f"Unexpected archive source marker: {directory}")
            destination = "build/deps/" + name
            origins.append({"path": destination, "url": url, "archive_sha256": expected, "strip_components": int(strip)})
            tree(directory, destination, source_archive=True)
    for name in SYNC_FILES:
        add(ROOT / f"build/deps/synctex-{SYNC_REV}" / name, f"build/deps/synctex-{SYNC_REV}/{name}")
    origins.append({"path": f"build/deps/synctex-{SYNC_REV}", "revision": SYNC_REV, "url": f"https://github.com/sumatrapdfreader/sumatrapdf/tree/{SYNC_REV}/ext/synctex"})
    symlinks = {}
    for path, destination in links:
        resolved = path.resolve(strict=True)
        # Dependency aliases point into other allowlisted source directories.
        matches = [name for name, source in files.items() if source == resolved or resolved in source.parents]
        if resolved.is_dir() and matches:
            target = str(Path(matches[0]).parents[len(files[matches[0]].relative_to(resolved).parts) - 1])
        elif resolved.is_file() and matches:
            target = matches[0]
        else:
            raise RuntimeError(f"Source link escapes the allowlist: {path}")
        symlinks[destination] = os.path.relpath(target, str(Path(destination).parent))
    for destination, revision in git_revisions.items():
        files[destination + "/.sumra-source-revision"] = (revision + "\n").encode()
    files["SOURCE_PACKAGE_BUILD.md"] = (
        "# Building the exported Sumra source\n\n"
        "This is the release source snapshot with the existing patches applied.\n"
        "Its provenance records exact upstream revisions and the actual file hashes.\n"
        "See provenance.json for frozen build-receipt correspondence and the\n"
        "bounded source/notice review status. Receipt matching is not reproducibility.\n\n"
        "After verifying SHA256SUMS, extract into a new empty directory with\n"
        "`tar -xkzf Sumra-corresponding-source.tar.gz -C <empty-directory>`.\n"
        "Compare extracted file SHA256 values and relative symlink targets to\n"
        "the `files` and `symlinks` objects in the accompanying provenance.json.\n\n"
        "Run from Sumra-source on macOS with the build prerequisites listed in README.md:\n\n"
        "- `./scripts/build-engines.sh` rebuilds the four native engines and ConvertLIT.\n"
        "- `./scripts/build-app.sh --release` builds and packages the GUI app.\n"
        "- `./scripts/check-source.sh` runs the unified source and test checks.\n\n"
        "MuPDF and JPEGXR have no Git metadata in this export. Matching\n"
        "`.sumra-source-revision` markers tell the existing build script to use the\n"
        "included source and recursive submodules without checking out over them.\n"
        "Archive-source dependencies retain their verified `.leaf-source` markers.\n"
        "Both kinds of markers identify provenance; file hashes identify the patched bytes.\n\n"
        "SwiftPM continues to resolve the pinned Sparkle binary framework. Its matching\n"
        "upstream source is included under upstream/Sparkle. This does not change\n"
        "the dependency strategy or establish a complete offline SwiftPM build.\n"
        "No private signing identity or update keys are supplied. The default result\n"
        "is an ad-hoc signed, nonnotarized local application.\n"
    ).encode()
    records = {name: {"sha256": digest(path), "bytes": len(path) if isinstance(path, bytes) else path.stat().st_size,
                      "mode": 0o644 if isinstance(path, bytes) else stat.S_IMODE(path.stat().st_mode),
                      **({"generated": True} if isinstance(path, bytes) else {})} for name, path in sorted(files.items())}
    return files, symlinks, {"origins": origins, "files": records, "symlinks": symlinks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, help="Write source inventory JSON without creating archives")
    parser.add_argument("--app", type=Path, help="Verified candidate .app to archive")
    parser.add_argument("--app-archive", type=Path, help="Reuse an already signed app ZIP on the same filesystem")
    parser.add_argument("--output", type=Path, help="New output directory; existing directories are refused")
    parser.add_argument("--source-receipt", type=Path, help="Frozen full source inventory JSON")
    parser.add_argument("--build-receipt", type=Path, help="Frozen successful build gate JSON")
    args = parser.parse_args()
    if bool(args.app) != bool(args.output):
        parser.error("--app and --output must be supplied together")
    if args.app_archive and not args.app:
        parser.error("--app-archive requires --app and --output")
    if bool(args.source_receipt) != bool(args.build_receipt):
        parser.error("--source-receipt and --build-receipt must be supplied together")
    if args.source_receipt and not args.app:
        parser.error("frozen receipts require --app and --output")
    files, symlinks, provenance = inventory()
    provenance.update(status="nonnotarized-release-artifacts", redistribution_audit="bounded_review_no_demonstrated_missing_inputs", source_build_match="not_attested", project_revision=git(ROOT, "rev-parse", "HEAD").decode().strip())
    print(f"Allowlisted {len(files)} source files, {len(symlinks)} relative links; {sum(item['bytes'] for item in provenance['files'].values())} bytes.")
    if args.inventory:
        with args.inventory.open("x") as handle:
            json.dump(provenance, handle, indent=2)
            handle.write("\n")
    if not args.output:
        return
    app = args.app.resolve(strict=True)
    if app.suffix != ".app" or not (app / "Contents/MacOS/Sumra").is_file():
        raise RuntimeError("Expected a packaged Sumra.app")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    candidate_inventory = app_inventory(app)
    provenance.update(candidate_inventory)
    provenance["app_metadata"] = app_metadata(app)
    if args.source_receipt:
        provenance["frozen_build_receipts"] = validate_frozen_receipts(
            args.source_receipt, args.build_receipt, provenance, candidate_inventory, provenance["app_metadata"])
        provenance["source_build_match"] = "matches_frozen_build_receipt"
    provenance["build_host"] = {
        "macos": subprocess.check_output(["sw_vers"], text=True).strip(),
        "swift_toolchain": subprocess.check_output(["swift", "--version"], text=True, stderr=subprocess.STDOUT).strip(),
    }
    args.output.mkdir(parents=True, exist_ok=False)
    source_tar = args.output / "Sumra-corresponding-source.tar.gz"
    def anonymous(entry):
        entry.uid = entry.gid = 0
        entry.uname = entry.gname = ""
        return entry
    with tarfile.open(source_tar, "w:gz", dereference=False) as archive:
        for name, path in sorted(files.items()):
            if isinstance(path, bytes):
                entry = tarfile.TarInfo("Sumra-source/" + name)
                entry.size = len(path)
                entry.mode = 0o644
                archive.addfile(entry, io.BytesIO(path))
            else:
                archive.add(path, arcname="Sumra-source/" + name, recursive=False, filter=anonymous)
        for name, target in sorted(symlinks.items()):
            entry = tarfile.TarInfo("Sumra-source/" + name)
            entry.type = tarfile.SYMTYPE
            entry.linkname = target
            archive.addfile(entry)
    # Verify every archived file and link, including changes during tar reads.
    verify_source_archive(source_tar, provenance["files"], symlinks)
    version = provenance["app_metadata"]["info_plist"]["CFBundleShortVersionString"]
    app_zip = args.output / f"Sumra-{version}-macOS-arm64.zip"
    if args.app_archive:
        os.link(args.app_archive.resolve(strict=True), app_zip)
    else:
        archive_app(app, app_zip)
    verify_app_archive(app_zip, app.name, provenance["app_files"], provenance["app_symlinks"],
                       provenance["app_modes"], provenance["app_directories"])
    manifest = args.output / "provenance.json"
    manifest.write_text(json.dumps(provenance, indent=2) + "\n")
    notes = args.output / "README.txt"
    correspondence = (
        "Source and app match the frozen build receipts embedded in provenance.json.\n"
        "This establishes receipt correspondence, not reproducibility.\n"
        if args.source_receipt else "Source/build matching is not attested.\n"
    )
    notes.write_text(
        f"Sumra {version} — nonnotarized community release artifacts\n\n"
        + correspondence +
        "The bounded source/notice review found no demonstrated missing inputs.\n"
        "This archive does not establish Developer ID, notarization or Gatekeeper acceptance.\n\n"
        "Verify from this directory: shasum -a 256 -c SHA256SUMS\n"
        "Extract sources into a new empty directory:\n"
        "  mkdir source-extraction\n"
        "  tar -xkzf Sumra-corresponding-source.tar.gz -C source-extraction\n"
        "Source file hashes and relative link targets are listed in provenance.json.\n"
        "The packager verifies complete file/link membership, types, file modes, bytes and link\n"
        "targets against that inventory before success.\n"
        "Project sources retain all local patches, resources, licenses and build scripts.\n"
        "Public upstream test fixtures are included as part of upstream source trees.\n"
        "The allowlist excludes repository metadata, session data and local build/test evidence.\n"
        "See Sumra-source/README.md for macOS build prerequisites. Sparkle's matching\n"
        "source is in upstream/Sparkle; SwiftPM resolves the existing pinned binary framework.\n"
    )
    (args.output / "SHA256SUMS").write_text("".join(f"{digest(path)}  {path.name}\n" for path in (source_tar, app_zip, manifest, notes)))
    print(f"Created verified release artifacts in {args.output}; publication is a separate action. The app is not notarized.")


if __name__ == "__main__":
    main()
