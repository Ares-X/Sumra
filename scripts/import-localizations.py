#!/usr/bin/env python3
"""Add reviewed SumatraPDF translations through its public, read-only history GET.

History and contributor records stay in memory. Existing translations, English
and the hand-maintained Simplified Chinese catalog are never replaced.
"""

import csv
import hashlib
import io
import json
from pathlib import Path
import re
import urllib.request


URL = "https://www.apptranslator.org/api/dltranshist?app=SumatraPDF&size=0"
ROOT = Path(__file__).resolve().parents[1] / "Sources/Sumra/Resources/Localizations"
# Historical Sumatra language identifiers, as listed in TranslationLangs.cpp.
LANGUAGES = {
    "be": "by", "ca-ES-valencia": "ca-xv", "ckb": "ku", "cs": "cz",
    "da": "dk", "fy": "fy-nl", "hy": "am", "ko": "kr", "ms": "my",
    "my": "mm", "nb": "no", "pt-BR": "br", "pt-PT": "pt",
    "sr-Cyrl": "sr-rs", "sr-Latn": "sp-rs", "vi": "vn", "zh-Hant": "tw",
}
EXACT = (
    "# History", "* Annotations", "= Settings", "> Commands", "@ Tabs",
    "Clear History", "Document Properties", "Dots", "Dotted lines",
    "Frequently Read", "Open", "Pin", "Recently Opened", "Redo",
    "Restore Tab Group", "Save Tab Group", "Search", "Set", "Solid lines",
    "Translate", "Undo", "Unpin", "Zoom",
    "Bold", "Circle", "Contribute Translation", "Delete Pages", "Extract Pages", "Extract Text",
    "Italic", "None", "Search Image with Google Lens", "Square", "Underline",
    "Page scaling", "Update EU Trusted List",
)
# Explicit equivalent labels/actions, checked against Sumatra 012d997f. No fuzzy
# key matching: Contents: is annotation text, while Contents is the reader's TOC;
# & Pages has a real palette prefix and must not inherit the plain Pages label.
ALIASES = {
    "Appearance": "Appearance:",
    "Automatically check for updates": "Automatically check for &updates",
    "Cursor Position": "Cursor position:",
    "Default layout": "Default &Layout:",
    "From": "From:",
    "Go to Page": "Go to page",
    "Loading…": "Loading...",
    "Margin": "Margin:",
    "Open in New Tab": "open in new tab",
    "Pages": "Pages:",
    "Rename": "Re&name...",
    "Rename File": "Rename File...",
    "Subdivisions": "Subdivisions:",
    "Thumbnails": "& Thumbnails",
    "To": "To:",
    "Translate Selection": "Translate Selection...",
    "Translate Selection…": "Translate Selection...",
    "Unsaved Changes": "Unsaved changes",
    # Annotation property controls: AnnotEditToolbar.cpp, especially its hover
    # rows at 3136–3187. Contents here is the annotation body, not the book's TOC.
    "Author": "Author:",
    "Border width": "Border Width",
    "Line end": "Line End",
    "Line start": "Line Start",
    "Text color": "Text Color",
    "Text size": "Text Size",
    "Annotation contents": "Contents:",
    "Comment": "Contents:",
    "Copy Link Address": "Copy Link &Address",
    "Copy Comment": "Copy Co&mment",
    "Show Comment": "Sho&w Comment",
    "Alignment": "Text Alignment",
    "Font family": "Text Font:",
    "Background": "Background Color",
    # These are the same signature fields and appearance checkboxes as
    # SignDocumentDialog.cpp:780–809, including the optional reason/location.
    "Labels": "Show &labels",
    "Name": "Show &name",
    "Distinguished name": "Show &DN",
    "Date": "Show da&te",
    "Graphic name": "Show name as &graphic",
    "Certificate password": "&Password:",
    "Reason": "&Reason (optional):",
    "Location": "&Location (optional):",
    "Digital Signature": "Sign Document",
    "Page": "Page:",
    "Go": "Go to page",
    "Go to Page…": "Go to Page...",
    "Extract": "Extract Pages",
    "Discard": "Discard changes",
    "Save…": "Save...",
    # Menu.cpp routes these image commands to the clicked image, including PDF
    # page elements; the more explicit reader labels do not change their action.
    "Copy Embedded Image": "Copy Image",
    "Save Embedded Image…": "Save Image...",
    "Crop Embedded Image…": "Crop Image...",
    "Resize Embedded Image…": "Resize Image...",
    "Convert Embedded Image to PDF…": "Convert Image To PDF...",
    "Save Selection…": "Save As Image...",
    # Commands.cpp display names, matched to the existing command consumers.
    "Reload": "Reload Document",
    "Open without History…": "Open File Without History...",
    "Remove Missing Files": "Remove Deleted Files From History",
    "Forget": "Remove Selected Document From History",
    "Search Selection in Wikipedia": "Search Selection with Wikipedia",
    "Search Selection in Google Scholar": "Search Selection with Google Scholar",
    "Scroll Up a Page": "Scroll Up By Page",
    "Scroll Down a Page": "Scroll Down By Page",
    "Scroll Up Half a Page": "Scroll Up By Half Page",
    "Scroll Down Half a Page": "Scroll Down By Half Page",
    "Generate Contents from Headings": "Generate Table Of Contents",
    "Open Source at Reading Position": "Invoke Inverse Search",
    "Page Information Overlay": "Toggle Page Info",
    "Show PDF Page Boxes": "Toggle Page Boxes",
    "Show Page Grid": "Toggle Page Grid",
    "Read from Cursor": "Start Reading From Cursor Position",
    "Read Selection": "Start Reading Selection",
    "Add File Attachment…": "Create File Attachment Annotation",
    "Digitally Sign PDF…": "Sign Document...",
    "Fit Page in Single Page View": "Zoom: Fit Page and Single Page",
    "Fit Width in Continuous View": "Zoom: Fit Width And Continuous",
    "Page Thumbnails": "& Thumbnails",
    "Expand All Contents": "Expand All",
    "Collapse All Contents": "Collapse All",
    "Sort Bookmarks by Name": "Sort By Name",
    "Annotation List": "Annotations",
    # ReaderView's Previous/Next buttons perform the same page turns as the
    # upstream toolbar. Plain headings omit the palette's visible prefix.
    "Previous": "Previous Page",
    "Next": "Next Page",
    "History": "# History",
    "Commands": "> Commands",
    "Tabs": "@ Tabs",
    "Open without History": "Open File Without History...",
    # PrintWin11.cpp kScaleItems: these labels share the actual print policies.
    "Shrink pages to printable area": "&Shrink pages to printable area",
    "Fit pages to printable area": "&Fit pages to printable area",
    "Stretch pages to fill paper": "S&tretch pages to fill paper",
    "Actual size (1:1)": "A&ctual size (1:1)",
    "Rotate printout:": "&Rotate printout:",
    "Center page horizontally on the paper": "Center page hori&zontally on the paper",
}
SOURCES = {**dict.fromkeys(EXACT), **ALIASES}
SOURCES = {key: source or key for key, source in SOURCES.items()}
ENTRY = re.compile(r'^\s*("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");\s*$', re.M)


def label(key, source, value):
    # A translation may retain a Win32 mnemonic even when the source omits it.
    value = re.sub(r"[（(]&[A-Za-z0-9][）)]", "", value).strip()
    if "&" in source and source != "& Thumbnails":
        value = value.replace("&", "").strip()
    if source == "& Thumbnails" and value.startswith("&"):
        value = value[1:].lstrip()
    if source.endswith(":") and not key.endswith(":"):
        value = value.rstrip(" :：\u00a0")
    if source.endswith("..."):
        value = re.sub(r"(?:\.\.\.|…)\s*$", "", value).rstrip()
        if key.endswith("…"):
            value += "…"
    for prefix in ("# ", "* ", "= ", "> ", "@ "):
        if source.startswith(prefix) and not key.startswith(prefix) and value.startswith(prefix):
            value = value[len(prefix):].lstrip()
    # These are searchable palette categories, not accelerator markers. Some
    # upstream translations omit the marker; keep Sumra's visible prefix intact.
    if key[:2] in ("# ", "* ", "= ", "> ", "@ ") and not value.startswith(key[:2]):
        value = key[:2] + value
    return value


def update_catalogs(translations):
    total_added = total_entries = 0
    for path in sorted(ROOT.glob("*.lproj/Localizable.strings")):
        language = path.parent.stem
        if language in ("en", "zh-Hans"):
            continue
        original = path.read_text(encoding="utf-8")
        pairs = [(json.loads(key), json.loads(value)) for key, value in ENTRY.findall(original)]
        entries = dict(pairs)
        if len(pairs) != len(entries):
            raise ValueError(f"Duplicate catalog keys: {path}")
        # The checked-in snapshot already contains reviewed equivalent labels.
        # Reuse those through the same source mapping when no history record is
        # supplied; an explicitly empty server record still removes the value.
        available = {source: entries[key] for key, source in SOURCES.items() if key in entries}
        additions, missing = {}, []
        for key, source in SOURCES.items():
            if key in entries:
                continue
            value = translations.get((LANGUAGES.get(language, language), source), available.get(source, entries.get(source, "")))
            if not value.strip():
                missing.append(key)
                continue
            additions[key] = label(key, source, value)
        if additions:
            lines = [f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};"
                     for key, value in sorted(additions.items())]
            path.write_text(original.rstrip() + "\n" + "\n".join(lines) + "\n", encoding="utf-8")
        count = len(entries) + len(additions)
        total_added += len(additions)
        total_entries += count
        print(f"{language}: added {len(additions)}, total {count}, missing {json.dumps(missing, ensure_ascii=False)}")
    print(f"Total: added {total_added}, entries {total_entries}")


def main():
    with urllib.request.urlopen(URL, timeout=60) as response:
        data = response.read()
    print(f"Source: {URL}\nBytes: {len(data)}\nSHA-256: {hashlib.sha256(data).hexdigest()}")
    translations = {}
    wanted = set(SOURCES.values())
    # The upstream CSV is oldest-first. An empty last value removes a translation.
    for row in csv.reader(io.StringIO(data.decode("utf-8"))):
        if len(row) == 6 and row[0] == "t" and row[4] in wanted:
            translations[row[3], row[4]] = row[5]
    if not translations:
        raise ValueError("No reviewed translation records in the server response")
    update_catalogs(translations)


if __name__ == "__main__":
    main()
