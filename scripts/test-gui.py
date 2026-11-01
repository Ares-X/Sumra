#!/usr/bin/env python3
"""Run the external-app XCUITest journey with bounded, disposable video evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def stop_owned(process):
    if process is None:
        return
    # The group belongs to the private session created for this command. Check
    # members even after its leader exits; a test/build child can outlive it.
    def members():
        rows = subprocess.check_output(["ps", "-axo", "pid=,pgid=,stat="], text=True, timeout=5)
        return [int(p[0]) for line in rows.splitlines()
                if len(p := line.split()) == 3 and int(p[1]) == process.pid and not p[2].startswith("Z")]
    if members():
        os.killpg(process.pid, signal.SIGTERM)
        deadline = time.monotonic() + 15
        while members() and time.monotonic() < deadline:
            time.sleep(0.1)
        if members():
            os.killpg(process.pid, signal.SIGKILL)
    if process.poll() is None:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    remaining = members()
    if remaining:
        raise RuntimeError(f"Task process group has not released: {remaining}")


def run_logged(command, path, timeout, env=None):
    with path.open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        finally:
            stop_owned(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/Sumra.app")
    parser.add_argument("--fixture", type=Path, default=ROOT / "docs/demos/Reading-Notes.md")
    parser.add_argument("--test", default="testOpenCancelAddCloseAndContentsHover", help="One NativeReaderJourneyTests method per bounded run")
    parser.add_argument("--reuse-build", type=Path, help="Use an existing build-for-testing; not deleted")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    fixture = args.fixture.resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True, timeout=5)
    pids = [int(parts[0]) for line in processes.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == str(executable)]
    if len(pids) != 1:
        parser.error("Start exactly one instance of the selected candidate before testing")
    # Packaging moves the preceding bundle aside while its process can remain
    # alive. Its command name still says dist/Sumra.app; check mapped files.
    mapped = subprocess.check_output(["lsof", "-p", str(pids[0]), "-Fn"], text=True, timeout=10)
    loaded_paths = {line[1:] for line in mapped.splitlines() if line.startswith("n")}
    engine = app / "Contents/Frameworks/MuPDF.dylib"
    if str(executable) not in loaded_paths or str(engine) not in loaded_paths:
        parser.error("The running process has not loaded this candidate executable and MuPDF engine; relaunch it first")

    output_root = ROOT / "build/gui-acceptance"
    output_root.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix=time.strftime("%Y%m%d-%H%M%S-"), dir=output_root))
    scratch = tempfile.TemporaryDirectory(prefix="scratch-", dir=evidence)
    scratch_path = Path(scratch.name)
    result = {"app": str(app), "pid": pids[0], "version": info.get("CFBundleShortVersionString"),
              "build": info.get("CFBundleVersion"), "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
              "nativeEngineSHA256": hashlib.sha256(engine.read_bytes()).hexdigest(),
              "verifiedMappedFiles": [str(executable), str(engine)],
              "fixture": str(fixture), "test": args.test, "recordingSource": "XCTest UI Automation",
              "status": "NOT_RUN", "visualReview": "NOT_REVIEWED", "resources": str(evidence)}
    movie = evidence / "journey.mp4"
    result_bundle = scratch_path / "journey.xcresult"
    print(json.dumps({"event": "evidence", "path": str(evidence)}), flush=True)
    try:
        mode = subprocess.check_output(["/usr/bin/automationmodetool", "status"], text=True, timeout=5)
        result["automationMode"] = mode.strip()
        if "Automation Mode is disabled" in mode and "This device requires user authentication" in mode:
            result["status"] = "ENVIRONMENT_BLOCKED"
            result["productTestsExecuted"] = False
            result["error"] = "Authorize macOS UI Automation in Xcode before running this journey"
            return 1
        derived = args.reuse_build.resolve(strict=True) if args.reuse_build else scratch_path / "xcode"
        base = ["xcodebuild", "-project", str(ROOT / "tools/GUIAcceptance.xcodeproj"),
                "-scheme", "GUIAcceptance", "-destination", "platform=macOS",
                "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO"]
        if args.reuse_build is None:
            code = run_logged(base + ["build-for-testing"], evidence / "ui-build.log", 180)
            if code:
                raise RuntimeError("UI test build failed; see ui-build.log")
        started = time.monotonic()
        environment = os.environ.copy()
        environment["TEST_RUNNER_SUMRA_GUI_APP_PATH"] = str(app)
        environment["TEST_RUNNER_SUMRA_GUI_FIXTURE_PATH"] = str(fixture)
        environment["TEST_RUNNER_SUMRA_GUI_PID"] = str(pids[0])
        language = subprocess.run(["defaults", "read", info["CFBundleIdentifier"], "language"],
                                  capture_output=True, text=True, timeout=5)
        environment["TEST_RUNNER_SUMRA_GUI_LANGUAGE"] = language.stdout.strip() if language.returncode == 0 else "system"
        code = run_logged(base + ["test-without-building", "-only-testing:SumraUITests/NativeReaderJourneyTests/" + args.test,
                                  "-resultBundlePath", str(result_bundle),
                                  "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
                                  "-default-test-execution-time-allowance", "120"],
                          evidence / "ui-test.log", 180, environment)
        result["testExitCode"] = code
        result["testWallSeconds"] = round(time.monotonic() - started, 3)
        summary_process = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                          "--path", str(result_bundle), "--compact"],
                                         capture_output=True, text=True, timeout=20)
        if summary_process.returncode:
            raise RuntimeError("Could not read actual UI test results")
        summary = json.loads(summary_process.stdout)
        write_json(evidence / "test-summary.json", summary)
        initialization_blocked = any("Timed out while enabling automation mode" in f.get("failureText", "")
                                     for f in summary.get("testFailures", []))
        if initialization_blocked:
            result["status"] = "ENVIRONMENT_BLOCKED"
            result["productTestsExecuted"] = False
            result["error"] = "macOS requires user authentication to enable UI Automation"
            return 1
        result["assertionsPassed"] = code == 0 and summary.get("passedTests", 0) > 0 and summary.get("skippedTests", 0) == 0
        result["status"] = "ASSERTIONS_PASSED_REVIEW_PENDING" if result["assertionsPassed"] else "FAILED_REVIEW_PENDING"
        test_id = "NativeReaderJourneyTests/" + args.test + "()"
        activity = json.loads(subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "test-results", "activities", "--path", str(result_bundle),
             "--test-id", test_id, "--compact"], text=True, timeout=20))
        attachments = {}
        def collect(value):
            if isinstance(value, dict):
                for attachment in value.get("attachments", []):
                    payload = attachment.get("payloadId")
                    if payload:
                        attachments[payload] = attachment
                    else:
                        result.setdefault("unavailableAttachments", []).append(attachment)
                for key, child in value.items():
                    if key != "attachments":
                        collect(child)
            elif isinstance(value, list):
                for child in value:
                    collect(child)
        collect(activity)
        recording = next((a for a in attachments.values() if a.get("name", "").endswith(".mp4")), None)
        if recording is None:
            raise RuntimeError("XCTest did not retain its native recording; cannot claim visual acceptance")
        native_movie = scratch_path / "native.mp4"
        subprocess.run(["xcrun", "xcresulttool", "export", "object", "--legacy", "--path", str(result_bundle),
                        "--output-path", str(native_movie), "--id", recording["payloadId"], "--type", "file"],
                       check=True, stdout=subprocess.DEVNULL, timeout=20)
        def probe(path):
            return json.loads(subprocess.check_output(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration,size", "-show_entries",
                 "stream=nb_frames,width,height", "-of", "json", str(path)], text=True, timeout=15))
        result["nativeRecording"] = probe(native_movie)
        code = run_logged(["ffmpeg", "-v", "error", "-i", str(native_movie), "-an", "-vf",
                           "scale=w=min(1440\\,iw):h=-2", "-r", "12", "-c:v", "libx264", "-crf", "26",
                           "-preset", "veryfast", "-fs", "67108864", str(movie)], evidence / "video.log", 90)
        if code:
            raise RuntimeError("Native recording compression failed")
        compressed = probe(movie)
        result["recording"] = compressed
        source_duration = float(result["nativeRecording"]["format"]["duration"])
        duration = float(compressed["format"]["duration"])
        if source_duration - duration > 0.15:
            raise RuntimeError("Compressed recording was truncated at its disk bound")
        sheet_code = run_logged(["ffmpeg", "-v", "error", "-i", str(movie), "-vf",
                                 f"fps=8/{duration},scale=640:-2,tile=4x2", "-frames:v", "1",
                                 str(evidence / "review.png")], evidence / "frames.log", 30)
        if sheet_code:
            raise RuntimeError("Could not prepare visual review sheet")
        phases = []
        for attachment in attachments.values():
            name = attachment.get("name", "")
            if name.startswith(("fullscreen-", "resize-", "titlebar-", "contents-", "native-tab-", "ai-", "palette-")):
                phase = evidence / (name + ".png")
                subprocess.run(["xcrun", "xcresulttool", "export", "object", "--legacy", "--path", str(result_bundle),
                                "--output-path", str(phase), "--id", attachment["payloadId"], "--type", "file"],
                               check=True, stdout=subprocess.DEVNULL, timeout=15)
                phases.append(phase.name)
        result["phaseCaptures"] = phases
        for attachment in attachments.values():
            if attachment.get("name", "").startswith("App UI hierarchy"):
                subprocess.run(["xcrun", "xcresulttool", "export", "object", "--legacy", "--path", str(result_bundle),
                                "--output-path", str(evidence / "failure-hierarchy.txt"), "--id", attachment["payloadId"],
                                "--type", "file"], check=True, stdout=subprocess.DEVNULL, timeout=15)
                break
        result["status"] = "ASSERTIONS_PASSED_REVIEW_PENDING" if result["assertionsPassed"] else "FAILED_REVIEW_PENDING"
        result["retainedEvidence"] = "Compressed journey.mp4 and review.png; delete movie after visual review or retain only the reproduced failure interval"
    except (RuntimeError, subprocess.SubprocessError, OSError, ValueError) as error:
        result["status"] = "ERROR"
        result["error"] = str(error)
    finally:
        scratch.cleanup()
        result["nativeResultBundleRemoved"] = not result_bundle.exists()
        result["automationModeAfter"] = subprocess.check_output(["/usr/bin/automationmodetool"], text=True, timeout=5).strip()
        result["scratchRemoved"] = not scratch_path.exists()
        result["retainedBytes"] = sum(p.stat().st_size for p in evidence.rglob("*") if p.is_file())
        write_json(evidence / "result.json", result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0 if result["status"] == "ASSERTIONS_PASSED_REVIEW_PENDING" else 1


if __name__ == "__main__":
    raise SystemExit(main())
