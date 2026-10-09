#!/usr/bin/env python3
"""Apply the pinned MuPDF patches while preserving an unknown source state.

Later patches alter earlier patches' context, so reverse-checking each patch
against the final tree is not a valid already-applied test. Probe a temporary
copy of only patch-touched files in reverse patch order instead. This works
for both Git checkouts and exported corresponding-source trees.
"""

from __future__ import annotations

import hashlib
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile


# Pinned f030eda1 MuPDF base, restricted to files touched by this patch set.
# Exported source trees lack Git history, so this one digest detects unrelated
# edits after reversing the patches in the temporary probe.
BASE_SHA256 = "48581b9f77166c43ce07daec85e490117e5461e7b4f48b5d39db7e56a3210599"


def touched_paths(patches: list[Path]) -> list[PurePosixPath]:
    paths: set[PurePosixPath] = set()
    for patch in patches:
        for line in patch.read_text().splitlines():
            if line.startswith(("--- a/", "+++ b/")):
                path = PurePosixPath(line[6:])
                paths.add(path)
    return sorted(paths)


def source_digest(source: Path, paths: list[PurePosixPath]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        file = source.joinpath(*path.parts)
        data = file.read_bytes() if file.exists() else None
        digest.update(str(path).encode() + b"\0")
        if data is None:
            digest.update(b"\xff")
        else:
            digest.update(len(data).to_bytes(8, "big"))
            digest.update(data)
    return digest.hexdigest()


def probe(source: Path, paths: list[PurePosixPath], patches: list[Path], reverse: bool) -> tuple[bool, str]:
    with tempfile.TemporaryDirectory(prefix="sumra-mupdf-patches-") as name:
        temporary = Path(name)
        for path in paths:
            original = source.joinpath(*path.parts)
            if original.exists():
                target = temporary.joinpath(*path.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(original, target)
        for patch in reversed(patches) if reverse else patches:
            command = ["git", "-C", name, "apply"]
            if reverse:
                command.append("--reverse")
            result = subprocess.run([*command, str(patch)], capture_output=True, text=True)
            if result.returncode:
                return False, f"{patch.name}: {result.stderr.strip()}"
        if reverse and source_digest(temporary, paths) != BASE_SHA256:
            return False, "reversed source differs from the pinned base"
    return True, ""


def apply(source: Path, patches: list[Path]) -> None:
    for patch in patches:
        command = ["git", "-C", str(source), "apply"]
        subprocess.run([*command, str(patch)], check=True)


def main() -> int:
    if len(sys.argv) < 4:
        raise ValueError("Expected MuPDF source and ordered patch paths")
    source = Path(sys.argv[1])
    patches = [Path(name) for name in sys.argv[2:]]
    paths = touched_paths(patches)

    if source_digest(source, paths) == BASE_SHA256:
        fresh, fresh_error = probe(source, paths, patches, reverse=False)
        if not fresh:
            raise ValueError(f"Pinned base cannot take the patch sequence: {fresh_error}")
        needed = patches
    else:
        complete, complete_error = probe(source, paths, patches, reverse=True)
        if complete:
            return 0
        raise ValueError(
            "MuPDF tree is neither the clean pinned source nor the current patched source; "
            f"preserving its files. {complete_error}"
        )

    apply(source, needed)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"MuPDF patch setup: {error}", file=sys.stderr)
        sys.exit(1)
