# Reader workflow exploration — 2026-10-25

Scope: independent exploration of lifecycle, format routing, navigation, reading
settings, and saved defaults beyond the issue #42 sample. Existing lifecycle,
navigation, session-restoration, and preferences tests informed scenario choice;
this is a focused addition to those checks.

## Demonstrated defect

`ReaderState.saveFormatDefaults()` copied newly introduced per-document location
fields into format defaults while clearing only the earlier coordinate fields.
Two independent workflows reproduced the problem:

- Native Markdown continuous reading → save format defaults → open another book:
  the new reader inherited the old semantic passage and scroll fraction.
- Panned image → save format defaults → open another image: the new reader
  inherited the old normalized viewport offset.

The pre-fix focused run produced six failed assertions in these two scenarios;
the overlapping text/HTML replacement scenario passed. Evidence:
`build/issue42/broad-reader-before.log`.

The direct writer correction cleared those fields and the PDF coordinate marker.
The first focused post-fix check passed 10 tests with zero failures, including the
three new workflows, preferences import/export checks, existing Markdown defaults
coverage, and the live typography panel regression. Evidence:
`build/issue42/broad-reader-after.log`.

## Additional compatibility check

An old-store regression additionally checks opening a previously unopened native
Markdown file with already-contaminated format defaults. It requires ignoring the
old book's coordinates while retaining reading settings and leaving stored JSON
unchanged. Its pre-normalization baseline reproduced 10 coordinate assertion
failures: `build/issue42/broad-reader-legacy-before.log`.

The final implementation puts the conversion in
`ReadingPosition.formatSettings`. Saving format defaults and applying existing
format-default records both use that single representation. It removes page,
passage, scroll and viewport offsets, rotation, and PDF coordinate metadata;
typography, theme, zoom, layout, and reading direction remain format settings.
Per-document saved locations and explicit navigation positions still use their
normal restoration path.

The final focused run passed **11 tests, zero failures**:

```sh
swift test --filter 'ExploratoryReaderWorkflowTests|ReaderLifecycleTests/testMarkdownBookmarksUsePassagesAndRetainLegacyOrdering|ReaderPreferencesTests|ReaderAppearanceControlsTests/testTypographyPanelSelectsInstalledAndSupplementalFontsLive'
```

Evidence: `build/issue42/broad-reader-final.log`. The old-store test also confirms
that opening a document does not rewrite the original settings JSON. The four new
scenarios cover both the demonstrated defaults failure and overlapping text/HTML
opens with explicit settings, delayed search cancellation, and closing/reopening
the reader.

## Coverage limits

The new tests use real document loading and native passage capture, plus reader
state assertions. They do not establish visual viewport acceptance in a running
release bundle, physical printing, older macOS behavior, or every possible
document format. No application installation, runtime restart, release, remote
write, or dependency change occurred in this exploration.

## Owned process cleanup

Serena server PID 2688 and its SourceKit LSP child 2770 were identified by the
per-PID log containing this exploration's `ReaderState` symbol requests. Both
were stopped and confirmed absent. Shared SourceKit services and other agents'
servers were preserved. Focused Swift test processes exited normally; no owned
analysis, build, or test processes remain. Failure/pass logs are retained as the
minimal reproduction evidence.

## Native ebook page margins

Further GUI QA found white strips around dark FB2 content in facing and
continuous reading. The isolated QA preference domain selected builtin `dark`;
the hosted reproducer reported resolved theme `dark`, palette background
`#000000`, and both native scroll view and clip view `drawsBackground=false`.
Direct native page and viewport-tile captures reproduced white margin pixels,
so the defect was inside native page painting rather than scroll-view styling.

MuPDF already applies `@page` CSS to its root background and paints it across
the complete page in both full-page and indexed-region paths. The palette CSS
now includes that page background. Its existing native palette-prefix
normalization recognizes the additional color-only rule, preserving saved
passage identities. No engine/API change or additional bitmap conversion is
needed; PDF and image rendering paths are unchanged.

`NativeReflowBackgroundTests` covers all five builtin palettes and a custom
palette in finite and natural layouts, full-page and viewport-tile margin
pixels, unchanged embedded-image pixels, saved passage/style identity, and a
hosted dark FB2 facing/next-row/continuous workflow. The relevant 14-test native,
theme and reading-position focus passed, and the browser palette/image/explicit
CSS regression passed separately. Evidence:

- `build/issue42/reflow-background-before.log` — reproduced white margins;
  the initial probe also contained an exact-red image expectation corrected to
  compare unchanged decoded image pixels across palettes.
- `build/issue42/reflow-background-final.log` — 14 passed, zero failures.
- `build/issue42/reflow-background-browser.log` — one passed, zero failures.

The hosted test's final page-turn wait was subsequently tightened to require
actual advancement before sampling; the final full-suite run owns validation
of that test-only adjustment. Release-bundle GUI verification remains separate.
No owned persistent analysis processes were started for this follow-up; the
focused test processes exited normally.
