# Sumra 0.2.23 release acceptance

The user accepted the locally installed reader on November 1 after the persistent
PDF top-strip repair. The accepted development executable was
`9acfd6b232562a90174ccc84b107c3a5cf0bd72adf98fed5883e84245bc1da4e`, with MuPDF
`da1d019bf5c1194f13580bed8391b5179757a609ad72fde7391810055f70919c`.

## Verified development behavior

- A real MuPDF document in an AppKit/SwiftUI host reproduced a 40-point top gap
  before the fix. The repaired owner uses the existing toolbar-overlay policy;
  the original pixel and layout assertions pass.
- Paged, facing-page Fit Width checks preserve the raw reading origin and page
  when changing Hidden to Auto Hide or Shown to Auto Hide. The latter increases
  the viewport from 606 to 672 points while preserving origin 441 and page 2.
- A real native UI test on macOS 27.0.1 verifies top-hover reveal, body-hover
  dismissal and a full-screen round trip. Four native screenshots were reviewed.
  A macOS 26.6.2 guest independently verifies the same PDF and mouse interaction;
  its Auto Hide and dismissed screenshots match exactly.
- Related layout checks report 37 passed and 2 conditionally skipped. Fixed-page
  and appearance checks report 79 passed and 2 conditionally skipped. These are
  scoped runs, not an exhaustive final-product or all-issue guarantee.
- Earlier focused regressions and original-document GUI checks cover native
  tabs, saved groups, reading settings, two-page keyboard input, browser/native
  links, annotation dirty-state ordering, text previews and delayed PDF hashing.
  The reported PDF decodes all 454 pages and 101 bookmarks.

The complete local receipts are retained with the task's acceptance evidence.
Intermediate recordings, result bundles, duplicate images and owned guest
snapshots were removed after review. The VM and shared automation tools remain
available; the activity-specific automation mode is disabled.

## Release source checks

The complete local check run found one failing localization case: its 22
assertions identified five missing new clearance labels in the non-Chinese
catalogs. Those translations were completed without changing reader behavior.
All 25 catalogs now cover the managed inventory, the five localization tests
pass, packaging tests and Quick Look UTI registration checks pass, and all three
reader JavaScript syntax checks pass. The other cases from the complete run
retain their results; 25 app tests were conditionally skipped. The failed run
and focused repair checks are retained separately rather than relabeling the
original run as a clean pass.

## Formal release boundary

Version 0.2.23 uses build 25. The official candidate is built and signed from an
exact source commit through [the existing release workflow](RELEASE_ACTIONS.md).
The signed candidate's original-document checks, manifest, source correspondence
and publication/update results will be recorded here before declaring release
delivery complete. The development executable above is not the signed release.

## Issue scope

Individual verified bugs may be closed after public-byte and installation checks.
The broader review and feedback trackers remain open where reporter-specific
Brave/RGB conditions or the older layout comparison are unverified. Representative
performance measurements do not establish cold-cache or external-volume behavior.
User-deferred listening and physical-input judgments are not recorded as passed.
