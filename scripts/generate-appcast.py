#!/usr/bin/env python3
"""Generate release metadata using the pinned Sparkle tool and personal Keychain."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="Signed Sumra app ZIP")
    parser.add_argument("--output", type=Path, default=ROOT / "appcast.xml")
    parser.add_argument("--channel", help="Sparkle channel, e.g. prerelease")
    args = parser.parse_args()
    archive = args.archive.resolve(strict=True)
    config = json.loads((ROOT / "Assets/Updates.json").read_text())
    with zipfile.ZipFile(archive) as zipped:
        info = plistlib.loads(zipped.read("Sumra.app/Contents/Info.plist"))
    version = info["CFBundleShortVersionString"]
    with tempfile.TemporaryDirectory(prefix="Sumra-appcast-", dir=archive.parent) as temporary:
        stage = Path(temporary)
        os.link(archive, stage / archive.name)
        feed = stage / "appcast.xml"
        if (ROOT / "appcast.xml").exists():
            shutil.copyfile(ROOT / "appcast.xml", feed)
        command = [str(ROOT / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"),
                   "--account", config["keychain_account"], "--maximum-deltas", "0",
                   "--download-url-prefix", f"https://github.com/Ares-X/Sumra/releases/download/v{version}/",
                   "--link", "https://github.com/Ares-X/Sumra/releases",
                   "-o", str(feed)]
        if args.channel:
            command += ["--channel", args.channel]
        subprocess.run(command + [str(stage)], check=True)
        shutil.copyfile(feed, args.output)

if __name__ == "__main__":
    main()
