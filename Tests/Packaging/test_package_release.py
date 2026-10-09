"""Release archives must reproduce their inventoried files and links exactly."""
import hashlib
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/package-release.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class ArchiveCorrespondenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sumra-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.entries = [
            ("run.sh", "file", b"#!/bin/sh\nexit 0\n", 0o755),
            ("file.txt", "file", b"expected", 0o644),
            ("alias", "link", b"file.txt", 0o777),
        ]
        self.files = {name: {"sha256": hashlib.sha256(data).hexdigest(), "mode": mode, "bytes": len(data)}
                      for name, kind, data, mode in self.entries if kind == "file"}
        self.links = {"alias": "file.txt"}
        self.directories = {"": 0o755}

    def frozen_receipts(self):
        source_file = self.root / "frozen-source.json"
        source = {
            "status": "nonnotarized-local-candidate",
            "redistribution_audit": "pending",
            "source_build_match": "not_attested",
            "origins": [{"path": "project", "revision": "abc123"}],
            "project_revision": "abc123",
            "files": {"run.sh": self.files["run.sh"]},
            "symlinks": {"alias": "run.sh"},
        }
        source_file.write_text(json.dumps(source, indent=2) + "\n")
        build_file = self.root / "frozen-build.json"
        metadata = {"identifier": "fixture.app"}
        bundle = package.app_inventory(self.root / "fixture.app")
        build = {
            "build_exit": 0,
            "tests": {"core": 1, "app": 1, "failures": 0, "skipped": 0},
            "packaging_tests": 1,
            "source_inputs_sha256": package.digest(source_file),
            "final_source_inputs_sha256": package.digest(source_file),
            "bundle": bundle,
            "metadata": metadata,
        }
        build_file.write_text(json.dumps(build, indent=2) + "\n")
        return source_file, build_file, source, build, metadata


    def archive(self, format, entries):
        path = self.root / ("archive." + format)
        prefix = "Sumra-source/" if format == "tar.gz" else "Sumra.app/"
        if format == "tar.gz":
            with tarfile.open(path, "w:gz") as output:
                for name, kind, data, mode in entries:
                    entry = tarfile.TarInfo(prefix + name)
                    entry.mode = mode
                    if kind == "link":
                        entry.type = tarfile.SYMTYPE
                        entry.linkname = data.decode()
                        output.addfile(entry)
                    else:
                        entry.size = len(data)
                        output.addfile(entry, io.BytesIO(data))
        else:
            with warnings.catch_warnings(), zipfile.ZipFile(path, "w") as output:
                warnings.simplefilter("ignore", UserWarning)  # Deliberate duplicate fixture.
                directory = zipfile.ZipInfo(prefix)
                directory.create_system = 3
                directory.external_attr = (stat.S_IFDIR | 0o755) << 16
                output.writestr(directory, b"")
                for name, kind, data, mode in entries:
                    entry = zipfile.ZipInfo(prefix + name)
                    entry.create_system = 3
                    entry.external_attr = ((stat.S_IFLNK if kind == "link" else stat.S_IFREG) | mode) << 16
                    output.writestr(entry, data)
        return path

    def verify(self, format, path):
        if format == "tar.gz":
            package.verify_source_archive(path, self.files, self.links)
        else:
            package.verify_app_archive(path, "Sumra.app",
                                       {name: item["sha256"] for name, item in self.files.items()},
                                       self.links, {name: item["mode"] for name, item in self.files.items()}, self.directories)

    def reject(self, entries):
        for format in ("tar.gz", "zip"):
            with self.subTest(format=format):
                with self.assertRaises(RuntimeError):
                    self.verify(format, self.archive(format, entries))

    def test_complete_archives_preserve_executable_and_link(self):
        for format in ("tar.gz", "zip"):
            with self.subTest(format=format):
                self.verify(format, self.archive(format, self.entries))

    def test_missing_file_or_link_is_rejected(self):
        for removed in ("file.txt", "alias"):
            with self.subTest(removed=removed):
                self.reject([entry for entry in self.entries if entry[0] != removed])

    def test_extra_and_duplicate_entries_are_rejected(self):
        for extra in (("extra", "file", b"unexpected", 0o644), self.entries[0]):
            with self.subTest(extra=extra[0]):
                self.reject(self.entries + [extra])

    def test_file_and_link_type_substitutions_are_rejected(self):
        for name, replacement in (
            ("file.txt", ("file.txt", "link", b"run.sh", 0o777)),
            ("alias", ("alias", "file", b"file.txt", 0o644)),
        ):
            with self.subTest(name=name):
                self.reject([replacement if entry[0] == name else entry for entry in self.entries])

    def test_changed_bytes_and_link_target_are_rejected(self):
        for name, data in (("file.txt", b"changed"), ("alias", b"run.sh")):
            with self.subTest(name=name):
                self.reject([(n, kind, data if n == name else original, mode)
                             for n, kind, original, mode in self.entries])

    def test_lost_executable_permission_is_rejected(self):
        self.reject([(name, kind, data, 0o644 if name == "run.sh" else mode)
                     for name, kind, data, mode in self.entries])

    def test_zip_directory_membership_and_type_are_checked(self):
        for name, kind in (("outside/", stat.S_IFDIR), ("Sumra.app/", stat.S_IFDIR),
                           ("Sumra.app/run.sh/", stat.S_IFDIR)):
            with self.subTest(name=name, kind=kind), warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                path = self.archive("zip", self.entries)
                with zipfile.ZipFile(path, "a") as output:
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = (kind | 0o755) << 16
                    output.writestr(entry, b"")
                with self.assertRaises(RuntimeError):
                    self.verify("zip", path)

    def test_zip_missing_or_mistyped_directory_is_rejected(self):
        for replacement in (None, stat.S_IFLNK | 0o755, stat.S_IFDIR | 0o700):
            with self.subTest(replacement=replacement):
                path = self.archive("zip", self.entries)
                with zipfile.ZipFile(path) as archive:
                    contents = [(entry, archive.read(entry)) for entry in archive.infolist()]
                with zipfile.ZipFile(path, "w") as archive:
                    for entry, data in contents:
                        if entry.filename == "Sumra.app/":
                            if replacement is None:
                                continue
                            entry.external_attr = replacement << 16
                        archive.writestr(entry, data)
                with self.assertRaises(RuntimeError):
                    self.verify("zip", path)

    @unittest.skipUnless(shutil.which("ditto"), "macOS ditto integration")
    def test_actual_ditto_app_directories_executable_and_symlink(self):
        app = self.root / "Sumra.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        executable = app / "Contents/MacOS/Sumra"
        executable.write_bytes(b"#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        (app / "Contents/Current").symlink_to("MacOS")
        archive = self.root / "ditto.zip"
        package.archive_app(app, archive)
        package.verify_app_archive(archive, app.name,
                                   {"Contents/MacOS/Sumra": package.digest(executable)},
                                   {"Contents/Current": "MacOS"}, {"Contents/MacOS/Sumra": 0o755},
                                   {"": 0o755, "Contents": 0o755, "Contents/MacOS": 0o755})

    @unittest.skipUnless(shutil.which("ditto") and shutil.which("xattr"), "macOS metadata integration")
    def test_actual_archive_omits_benign_xattrs_without_changing_product(self):
        app = self.root / "Sumra.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        executable = app / "Contents/MacOS/Sumra"
        executable.write_bytes(b"#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        (app / "Contents/Current").symlink_to("MacOS")
        subprocess.run(["xattr", "-w", "com.sumra.packaging-test", "benign", str(executable)], check=True)
        before = package.app_inventory(app)
        archive = self.root / "metadata-free.zip"
        package.archive_app(app, archive)
        package.verify_app_archive(archive, app.name, before["app_files"], before["app_symlinks"],
                                   before["app_modes"], before["app_directories"])
        self.assertEqual(package.app_inventory(app), before)
        self.assertEqual(subprocess.check_output(["xattr", "-p", "com.sumra.packaging-test", str(executable)]).strip(), b"benign")

    @unittest.skipUnless(shutil.which("ditto") and shutil.which("xattr"), "macOS resource fork integration")
    def test_real_resource_fork_is_rejected_before_lossy_archive(self):
        app = self.root / "Sumra.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        executable = app / "Contents/MacOS/Sumra"
        executable.write_bytes(b"product bytes")
        resource = b"required resource data"
        subprocess.run(["xattr", "-w", "-x", "com.apple.ResourceFork", resource.hex(), str(executable)], check=True)
        archive = self.root / "unsupported-fork.zip"
        with self.assertRaisesRegex(RuntimeError, "resource fork"):
            package.archive_app(app, archive)
        self.assertFalse(archive.exists())
        self.assertEqual(executable.read_bytes(), b"product bytes")
        value = subprocess.check_output(["xattr", "-p", "-x", "com.apple.ResourceFork", str(executable)], text=True)
        self.assertEqual(bytes.fromhex(value), resource)

    @unittest.skipUnless(shutil.which("ditto"), "macOS ditto integration")
    def test_packager_writes_verified_source_and_app_archives(self):
        app = self.root / "Sumra.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        executable = app / "Contents/MacOS/Sumra"
        executable.write_bytes(self.entries[0][2])
        executable.chmod(0o755)
        (app / "Contents/Current").symlink_to("MacOS")
        source = self.root / "run.sh"
        source.write_bytes(self.entries[0][2])
        source.chmod(0o755)
        inputs = {"run.sh": source, "file.txt": b"expected"}
        provenance = {"files": self.files, "symlinks": self.links, "origins": []}
        output = self.root / "candidate"
        real_run = subprocess.run

        def run(command, **kwargs):
            if command[0] == "codesign":
                # This fixture is not a signed application. Signing is a separate gate.
                return subprocess.CompletedProcess(command, 0)
            return real_run(command, **kwargs)

        with mock.patch.object(package, "inventory", return_value=(inputs, self.links, provenance)), \
             mock.patch.object(package, "app_metadata", return_value={"info_plist": {"CFBundleShortVersionString": "0.2.0"}}), \
             mock.patch.object(package.subprocess, "run", side_effect=run), \
             mock.patch("sys.argv", ["package-release.py", "--app", str(app), "--output", str(output)]), \
             contextlib.redirect_stdout(io.StringIO()):
            package.main()
        package.verify_source_archive(output / "Sumra-corresponding-source.tar.gz", self.files, self.links)
        snapshot = package.app_inventory(app)
        package.verify_app_archive(output / "Sumra-0.2.0-macOS-arm64.zip", app.name,
                                   snapshot["app_files"], snapshot["app_symlinks"],
                                   snapshot["app_modes"], snapshot["app_directories"])
        for line in (output / "SHA256SUMS").read_text().splitlines():
            expected, name = line.split("  ", 1)
            self.assertEqual(package.digest(output / name), expected)


class FrozenReceiptTests(unittest.TestCase):
    def setUp(self):
        ArchiveCorrespondenceTests.setUp(self)
        app = self.root / "fixture.app"
        app.mkdir()
        (app / "run.sh").write_bytes(self.entries[0][2])
        (app / "run.sh").chmod(0o755)
        (app / "alias").symlink_to("run.sh")
        self.app = app
        self.source_path, self.build_path, self.source, self.build, self.metadata = ArchiveCorrespondenceTests.frozen_receipts(self)
        self.manifest = {**self.source, "project_revision": "abc123"}

    def test_matching_source_and_app_receipts_validate_and_are_embedded(self):
        result = package.validate_frozen_receipts(
            self.source_path, self.build_path, self.manifest, package.app_inventory(self.app), self.metadata)
        self.assertEqual(result["source_build_match"], "matches_frozen_build_receipt")
        self.assertEqual(result["source_receipt_sha256"], package.digest(self.source_path))
        self.assertEqual(result["build_receipt_sha256"], package.digest(self.build_path))
        self.assertIn("not reproducibility", result["claim_limit"])

    def test_receipt_correspondence_uses_artifacts_without_process_status_gates(self):
        del self.source["status"]
        del self.source["redistribution_audit"]
        self.source_path.write_text(json.dumps(self.source))
        del self.build["tests"]
        del self.build["packaging_tests"]
        self.build["source_inputs_sha256"] = package.digest(self.source_path)
        self.build["final_source_inputs_sha256"] = package.digest(self.source_path)
        self.build_path.write_text(json.dumps(self.build))
        result = package.validate_frozen_receipts(
            self.source_path, self.build_path, self.manifest, package.app_inventory(self.app), self.metadata)
        self.assertEqual(result["source_build_match"], "matches_frozen_build_receipt")

    def test_changed_source_bytes_are_rejected(self):
        changed = dict(self.manifest)
        changed["files"] = {"run.sh": {**self.files["run.sh"], "sha256": "0" * 64}}
        with self.assertRaisesRegex(RuntimeError, "allowlisted source"):
            package.validate_frozen_receipts(
                self.source_path, self.build_path, changed, package.app_inventory(self.app), self.metadata)

    def test_changed_app_bytes_or_link_target_are_rejected(self):
        (self.app / "run.sh").write_bytes(b"changed")
        with self.assertRaisesRegex(RuntimeError, "app does not match"):
            package.validate_frozen_receipts(
                self.source_path, self.build_path, self.manifest, package.app_inventory(self.app), self.metadata)

    def test_unbound_or_failed_gate_is_rejected(self):
        self.build["source_inputs_sha256"] = "0" * 64
        self.build_path.write_text(json.dumps(self.build))
        with self.assertRaisesRegex(RuntimeError, "does not bind"):
            package.validate_frozen_receipts(
                self.source_path, self.build_path, self.manifest, package.app_inventory(self.app), self.metadata)
        self.build["source_inputs_sha256"] = package.digest(self.source_path)
        self.build["final_source_inputs_sha256"] = package.digest(self.source_path)
        self.build["build_exit"] = 1
        self.build_path.write_text(json.dumps(self.build))
        with self.assertRaisesRegex(RuntimeError, "unsuccessful build"):
            package.validate_frozen_receipts(
                self.source_path, self.build_path, self.manifest, package.app_inventory(self.app), self.metadata)

if __name__ == "__main__":
    unittest.main()
