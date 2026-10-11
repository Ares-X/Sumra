# Local book corpus acceptance

This report describes sampled validation of 25 locally supplied books. The books and raw measurements are not part of the public source export. Tests and probes that open and sample them do not certify complete page/text fidelity, performance parity or public release. The [current release checklist](RELEASE_CHECKLIST.md) and [product matrix](SUMATRA_PARITY.md) carry the open decisions.

| Input group | Count | Material boundary |
| --- | ---: | --- |
| EPUB | 14 | All have NCX; one declares fixed layout. Large reflow outlines and page counts stress lazy chapter publication. |
| PDF | 2 | Page/outline destinations and live edit/print routes require independent checks. |
| Comic archives | 3 | Up to 2,100 images, including a solid archive whose unseen seeks remain expensive. |
| TXT | 2 | The larger is about 51 MB and stresses long-line layout and distant position restoration. |
| Markdown | 2 | About 14 and 21 MB, with very long lines and browser high-zoom limits. |
| CHM | 1 | More than 2,000 HHC entries and many GBK topics, including an extensionless linked topic. |
| MOBI | 1 | Unencrypted MOBI 6/PalmDOC; it has no NCX/INDX navigation records. |

The recorded 25/25 functional sweep exited successfully for opening, sampled rendering and navigation; originals remained byte-identical by inventory checks. This was a bounded local probe, with separate older app-window observations. It does not establish every page, whole-book search/selection, low memory, smooth trackpad use or the current loaded binary's behavior. CHM follows its own WebKit navigation checks. Some source outline targets are missing or empty by design; an empty MOBI outline is not automatically a parser failure.

## Published 0.2.2 Actions acceptance (2026-10-11)

The public app was built from `ad996417fdd2a061f7399cfb10c601e59366a6f0`;
its executable UUID is `D5A599B0-D4AA-3DD9-8F15-74630815496A`. The final
changed-owner checks use this app. Earlier corpus observations below retain
their own binary identities.

| Original Markdown | Source open to first painted canvas | First chapter layout | Single/Two/Continuous layout | End-of-session physical footprint | Process lifetime peak |
| --- | ---: | ---: | ---: | ---: | ---: |
| B02, 14.17 MB | 1.434 s | 0.898 s | 0.390–0.397 s | 527 MiB | 971 MiB |
| B04, 20.65 MB | 2.308 s | 1.755 s | 0.542–0.544 s | 656 MiB | 968 MiB |

These are separate fresh-process observations on an M3 Max running macOS
27.0.1, with different window geometry. Memory includes mode switching,
completed Find and Contents navigation; it is not a first-open-only sample
or an upstream performance comparison. Both books passed actual Single/Two
Page turns, same-chapter continuous wheel movement, completed 47/336-result
Find and Next, Contents destinations, and fresh-process restoration of the
same 100-character source passage and exact recorded scroll fraction.

The mode owner now publishes chapter geometry with the committed reading
surface. Queued requests from the preceding mode are canceled before location
projection or rendering, preventing an obsolete finite-page request from
rasterizing a newly natural-height chapter. Nine focused reader/rendering
checks passed after red/green regressions. Final runtime logs confirm discarded
obsolete requests and viewport rendering below 0.039 seconds in these sessions.
The final EPUB check also preserves its entire 415-character continuous
passage from the preceding double-page spread. TXT and CHM checks use their
unchanged owners and separately identified earlier GUI captures.

[Candidate build](https://github.com/Ares-X/Sumra/actions/runs/38146117699)
and [publication](https://github.com/Ares-X/Sumra/actions/runs/38147751273)
succeeded. All six [public release assets](https://github.com/Ares-X/Sumra/releases/tag/v0.2.2)
downloaded anonymously and matched the accepted hashes. Strict application
signing and the Sparkle update signature passed. A real public 0.2.1 client
downloaded, installed and relaunched as 0.2.2; its 181 files and five symlinks
match the accepted app. The same bytes were loaded into canonical
`dist/Sumra.app`, where B04 restoration and continuous movement passed again.

The first B04 readiness observation immediately after updating was 13.528
seconds. Its cause remains undetermined: reader debug events were not retained
for that run, and no matching security-policy event was found. Two subsequent
fresh processes painted the first canvas in 2.450 and 2.351 seconds. The slow
observation is retained as an anomaly, not attributed to the OS or omitted from
acceptance. All nine shipped Mach-O files include arm64 with a minimum system
version no newer than macOS 13; physical macOS 13 execution remains unexercised.

Private receipts retain the original inventory, GUI captures, performance
events, release correspondence and process/output retirement evidence.

## Completed original-book workflow sweep (2026-10-11)

The subsequent large-Markdown follow-up was loaded as `0DC4E5D7` and repeated
both original B02/B04 workflows in fresh GUI processes. Single/Two Page turns,
continuous scrolling, 47/336 completed Find results and Next, Contents jumps,
width reflow and fresh-process reopening passed. The same 100-character source
excerpt and scrollbar fraction were restored after reopening. Initial layout,
mode-change and physical-footprint measurements retain their distinct scopes
in the [pagination performance record](LARGE_TEXT_PERFORMANCE_20261010.md#final-pagination-follow-up-october-11).
All 25 originals again match inventory size, nanosecond modification time and
SHA-256 after these checks.

All 25 inventoried originals were exercised in the canonical GUI with the
applicable reading controls, not just opened by a probe. Evidence spans main
`99CA6A9A`, the scan/accessibility fixes in `0664DB94`, and search-proof reuse
in `4D73AF77`; the latter two use MuPDF `C860B4AF`. Later changed-owner checks
are recorded separately rather than assigning every earlier capture a new UUID.
The private receipts are in `build/validation-other-format-acceptance-20261011`.

| Originals | Actual sampled workflow and result |
| --- | --- |
| Reflow EPUB B01, B03, B08–B10, B15–B19, B21–B23 | Font changes and sidebar width rewrap; source Contents destinations; Single/Two Page navigation; natural continuous scrolling; completed Find and continuation/wrap; fresh-process reopening retains an 80-character visible source passage. |
| Markdown B02, B04 (14.17 / 20.65 MB) | Font/width reflow, Contents, Single/Two Page turns and natural continuous movement; `Spell` Find advances through 47 / 336 matches; settled fresh-process reopening retains the visible source passage. Immediate pending captures are excluded. |
| CHM B05 | Reader font/width reflow, topic Contents, Single/Two column advancement, actual WebKit continuous wheel movement; completed 5,000+ result search advances topic 61→63. Fresh-process topic 61 restores the same scroll fraction and near-identical painted crop. |
| MOBI B13 | Reader typography and six detected Contents entries; Single/Two Page turns, natural scrolling, completed Find/wrap, and fresh-process passage plus scroll restoration. |
| TXT B14 / B25 (0.545 / 51.61 MB) | Font/width reflow, Single/Two Page turns, native continuous movement and completed Find. Fresh-process reopening retains the entire captured visible text (636 / 987 characters in the recorded comparisons). B14 has no genuine standalone chapters; its empty Contents is correct. B25's detected chapter destinations were exercised. |
| PDF B06 / B20 | Authored page fitting, outline navigation, Single/Two Page turns, continuous scrolling, completed Find/continuation, and fresh-process page/scroll/source restoration. B06 additionally passes scanned-text contrast enabled/disabled and persisted choice. |
| Comic archives B07, B11, B24 | Folder Contents, fitting and Single/Two/Continuous navigation. Settled fresh-process page/scroll restoration has identical painted crop pixels. B07 is a solid 7z archive despite its `.cbz` suffix; unseen decoding cost remains. |
| Fixed EPUB B12 | Authored image geometry, 31 source Contents destinations, Single/Two/Continuous movement, restored page/scroll and near-identical image crop. Its source has no extractable body text; completed 0/0 Find is expected. |

The original EPUB B10 search was allowed to finish: 916 matches and successful
continuation 27→28. B07's first gray-placeholder comparison was rejected and
repeated after actual painting; page 532 and its middle crop then match exactly.
TXT B14's first differing background capture was investigated separately: text
ranges already matched, and a settled repeat matched the painted passage too.
Those rejected observations remain diagnostic evidence, not extra passes.

A late B04 Contents check initially mistook an immediate capture for a lost
mouse jump. Event-to-scroll tracing instead proves that the original mouse
activation executes and queues subsequent keyboard requests correctly, but
first destination resolution takes about 2.84 seconds. Mouse-only navigation
and reactivating the selected entry after scrolling the body both reach the
correct heading. The unnecessary click-owner rewrite was withdrawn; the
destination now passes its existing viewport to passage extraction. In final
main `C0630A46` / MuPDF `C860B4AF`, a fresh-process mouse jump shows the correct
heading within the 984 ms observation, and reactivating the selected entry after
body scrolling returns to that heading. The sampled process is 530 MB physical
footprint with an 843 MB peak. Closing the sidebar and reopening from a new Home
process retain the 80-character source passage and exact scroll fraction.
This is a separate GUI observation, not a controlled speedup ratio.

The final full-engine release build completed with Python commands disabled.
It uses the new Swift packaging tool, passes deep strict signature verification,
and checks arm64/macOS 13 deployment targets and the bundled non-system
dependency closure. Source inventory also completes with the Swift tool. The
reader's earlier corpus receipts remain valid for their recorded binaries;
the final changed-owner GUI checks are separate `final-*` receipts.

Default appearance now uses the light palette for reading and Home. The existing
default was also selected through the normal Theme control and confirmed as
`Light` in Settings. Changing B25's dark text to light in `67FE2244` exposed an
actual TextKit viewport loss (line 194677→168365); that observation is rejected
as a position pass. The foreground-attribute change now uses the existing
source-position restoration, with a red/green mounted neutral long-text test.
In final main `916B01AE`, the original B25 preserves all 822 captured visible
characters through Light→Dark→Light and a fresh-process reopen, at line 194677.
The painted body is confirmed as `#f2f2f2` in Light and after reopening; Dark is
only the explicit intermediate selection. Scrollbar estimates change while the
source passage stays identical, so they are not used as the TXT source oracle.
The fresh reopened process is 197 MB physical footprint with a 439 MB peak.
All 24 TextLayout tests pass. EPUB Contents/Find/wrap, CHM Contents/continuous
wheel navigation and the enhanced B06 scan were also rechecked in the preceding
light-default build; no later changes affect those owners.

The 25 originals retain their inventoried byte size, exact nanosecond mtime and
SHA-256 (`final-original-integrity.json`). This accepts the recorded workflows,
not every page or an overall performance budget. Scanned/fixed/image pages do
not have prose reflow or added OCR. There is no original RAR book in the corpus;
stored, unencrypted, non-solid RAR5 coverage is a neutral fixture, not original
RAR acceptance. Physical macOS 13/M1 execution and instrumented frame rates
remain unexercised; the user's normal-app manual drag feedback is retained below.

## Continued original-book workflow audit (2026-10-11)

### Prose whitespace follow-up

The screenshot's original MOBI passage retains repeated BR nodes and full-width
whitespace rows. Rewrapping had preserved those rows at the reader's line height.
Native reader reflow now gives ordinary whitespace-only rows no vertical advance,
keeping one hard newline. Empty text-only paragraphs also stop adding blank height
or affecting the surrounding normal paragraph margins. Their source nodes and
destinations remain present. Preformatted text, code, tables, image paragraphs,
explicit page breaks and fixed EPUB are excluded from this compaction.

The same corpus contains empty/NBSP paragraphs in B03 and several other EPUBs;
these are handled by the layout owner rather than rewriting archive contents.
Recognized fixed-column CHM prose now uses a compact paragraph gap independently
of its source blank-row count, retaining exact DOM text and Find offsets.
The native spacing/fixed-layout/search/reflow suite passes 46 tests; the CHM
browser suite passes 42. Their receipts are retained separately in
`build/validation-prose-spacing-20261011` and
`build/validation-reflow-spacing-20261011`.

The original B13 screenshot was reproduced at the same viewport. Row-start
separation across its repeated blank rows fell from 108 pixels to the normal
27-pixel line advance; the source file was unchanged. This paired image check
used the spacing engine `0E03A5D0-16ED-3B5F-927D-361729821423`. The final loaded
executable `B9AC7AE7-DC70-3707-A43A-5E575B50CA27` uses that same engine.
Its original-book Find completed at 1/1, with the passage visible in Single Page
(page 48/237), Two Pages (page 109/509) and Continuous reading after layout and
counting completed. Captures taken while finite layout is pending are not
treated as completed mode checks.

The app check also caught saved-position failures outside the spacing owner.
Converted native ebooks now use their actual source bytes for persistent source
identity, and preserve their source passage through mode and style changes.
Home-to-document mounting now delivers the source-resolved position with the
initial canvas bounds, instead of retaining the old numeric Y request.
The normal app reopened B13 from Home and visibly restored the supplied passage
before Find was invoked; content-free OCR confirms it in the body. A neutral
mounted Home regression failed before this fix, and six startup/ebook tests pass
after it, alongside the preceding 27 affected source-position tests. Those are
overlapping focused receipts, not a fresh summed full-suite result.

Original B05 completed its CHM query at 2/3, selected topic 56, retained that
selection through Two Pages and Continuous modes, and advanced its Continuous
bar from 0.005904059 to 0.1202952. The compact CHM gap's geometry is covered by
the WebKit tests; no same-viewport original CHM gap measurement is claimed.
The original TXT inputs B14 and B25 have only isolated blank lines, with no
consecutive empty-line runs. Their normal paragraph separators remain intact.

The final loaded app also reopened the original 20.65 MB Markdown from a fresh
Home process, completed all 336 matches and advanced from result 1 to result 2
with actual viewport movement. This is a functional confirmation; the earlier
performance measurements below retain their own executable and engine identity.
All 25 originals still match inventory size, modification time and SHA-256.
The final release build and strict deep signature verification passed; the
local development bundle remains ad-hoc signed and not notarized.

This follow-up uses the same 25 originals and the canonical graphical app. It
found failures beyond opening: finite EPUB Find waited for whole-book layout,
lost selection after changing modes, comic folders were absent from Contents,
and large continuous Markdown Find extracted the whole natural-height chapter
before publishing its first hit. These failures were reproduced in the app and
fixed at the corresponding layout, archive and native text owners.

Finite EPUB Find now searches the current chapter before laying out later
chapters. Stable chapter/page identities survive publication of additional page
counts; an active Find is restored after viewport reflow. On original B22,
`马尾拂尘` painted the selected single-page result in a 1.199-second GUI capture
after Return in executable `7447E813-BB77-3D67-814C-966E46BEA37B`. Changing to
Two Pages retained the visible result and later completed at 1/1. The previous
build's 38-second observation had reached 0/1 without its selected highlight.
Those observations are different builds, rather than a same-run benchmark.

The large TXT check also exposed a prose fragment beginning with a numbered
marker in Contents. It had no title separator, internal sentence punctuation,
and no blank paragraph boundary; repeated genuine numbered chapters had
incorrectly promoted it through the detector's family-consistency count.
Such compact, punctuated lines now need an actual paragraph boundary before
they can contribute to that count. Explicitly separated punctuated titles,
compact titles with a boundary and ordinary compact titles retain their
existing behavior. The original failing line is zero-based line 272884;
source-neutral diagnostics retain its shape without publishing book text.
The affected core suite passes 102 tests, including mixed newlines, stable
UTF-16/line offsets and the prose/valid-title boundary regressions.
The subsequently loaded normal executable
`4FA3A3AB-1460-3B09-97EC-C6285370D102` confirms that the offending prose query
returns no Contents entry, while the three genuine chapter matches remain.
Selecting the second reaches line 194678. The original compact title at
zero-based line 253369 remains in Contents, reaches displayed line 253370,
and small Continuous scrolling advances to 253371. The same build retains
all six original MOBI entries and its second-part destination. These checks
use the unchanged engine below; the earlier performance timings retain their
own measured executable identity.

Comic Contents now derives folder hierarchy from the existing naturally sorted
image-entry list used by the normal Archive/ImageIO consumer. ZIP, RAR and 7z
therefore share destinations without an unused MuPDF-only comic implementation.
Only folders containing images appear. Originals B07, B11 and B24 respectively
have 12, 95 and 12 chapter folders under their archive roots. Actual selections
reached pages 120, 97 and 1467; subsequent page/spread navigation progressed.
B07's header is solid 7z despite its `.cbz` suffix; it is not a RAR test.

No RAR original is present in this corpus. A neutral, stored, single-volume RAR5
fixture passed both decoder checks and normal-app `.cbr` and `.rar` opening.
Its nested Part 3 destination reached page 3, Chapter 10 reached page 4 in
Single Page, Two Pages painted two different images, and small Continuous
scrolling moved within the same viewport. This covers that RAR5 fixture;
encrypted, multi-volume and solid RAR archives were not exercised.

| Original format | Actual follow-up observations |
| --- | --- |
| Reflow EPUB | Body/Contents/search samples across all 13 reflow originals; Single/Two/Continuous transitions and small continuous scrolling on selected books, including B17 and B22. |
| Fixed EPUB B12 | Contents destination 327, forward page/spread progress and small continuous scrolling; publisher image geometry remains fixed. The exploratory text query was interrupted before completion and is not a negative-search proof. |
| PDF B06/B20 | Contents and highlighted search destinations, small continuous scrolling, single-page and spread advancement. |
| Comic B07/B11/B24 | Folder Contents and real page/spread advancement; pure-image Find stays unavailable. |
| CHM B05 | Three completed matches and selection at topic 56, Two Pages, and small Continuous scrolling from 0 to 0.0699052 in the later normal build. Earlier wide/narrow reflow and whole-title checks retain their scope. |
| MOBI B13 | Six detected entries, second-part destination, a completed chapter search, Single Page 3→4, spread navigation and small Continuous movement from 0.00668587 to 0.00701634. |
| Small TXT B14 | Opening and source-neutral heading diagnostics; the apparent chapter prefixes occur in prose lines, with no independently recognized chapter title. Empty Contents is expected for this input. |
| Large Markdown/TXT | Final first-paint, memory and search measurements are recorded in the performance report below; native probes and GUI observations retain separate scopes. |

Local evidence is retained in `build/validation-format-workflows-20261011`.
An earlier source gate passed 926 Swift tests (99 core, 827 app), 17 packaging
checks and three reader-script syntax checks. After the later native search
change, 37 unique affected native/integration tests passed. The integrated
paint/startup/EPUB/comic suite then passed 64 tests. These are overlapping
receipts, not a summed fresh full-suite total. The final app build performs the
arm64, minimum-macOS and private-library checks described in the performance
report. This remains sampled workflow acceptance; it does not certify every
page, OCR of image books, physical trackpad frame rate or macOS 13 execution.

The measured integrated executable is `68CA2284-C9A3-3B78-9A66-69C8B84F0186`,
with loaded engine `C9A795E7-1C54-32CD-A8C2-7D287E72D59E`. Final normal-app
checks repeated both large Markdown searches, the large TXT reading workflow,
B22's highlighted mode transitions and `.rar` chapter/page navigation. The
[performance report](LARGE_TEXT_PERFORMANCE_20261010.md) records their measured
scope. All 25 originals remain identical in size, modification time and SHA-256
after these checks.

## Current reading-effect audit (2026-10-10)

All 25 originals were opened through the native picker in the loaded canonical
application, with local window/AX receipts for each. This is an opening result,
not 25 complete reading-function passes. Small-scroll checks use observed scrollbar
movement or translated text pixels, rather than treating a successful scroll call
as evidence. Covers, blank front matter and body text are distinguished.

The audit exposed concrete defects beyond successful opening: CHM text topics used
tiny default typography and retained source-fixed 35-character lines; author-style
mode disabled the font controls. Font changes could also falsely detect the end
because a CHM document root was taller than its visible window. A separate classic
scrollbar regression showed why the end check must use the smaller of the window
height and root viewport height. Browser resize retains its actual top source
anchor, rather than moving to unrelated lower text just to keep an earlier test
glyph visible.

The CHM fixes retain exact topic text/search offsets and genuine paragraph/code
breaks while visually reflowing detected repeated Chinese prose columns. Plain
topics use reader typography, prose HTML containers fit the viewport, and changing
font/size/line spacing overrides author styles. Form and table widths remain
authored. Single-page CSS explicitly establishes columns on older WebKit.

The original MOBI has no authored TOC metadata. Its five chapter headings are
independent lines inside long paragraphs separated by `<br></br>`; a sixth
independent line names the second part. The initial paragraph-only detector
passed its fixtures but still produced empty Contents on the original. The
reader now feeds those visible source lines to the existing chapter detector
when no authored TOC exists, with destinations anchored at original decompressed
byte offsets. Authored TOCs retain priority. This fixes the actual missing
navigation consumer rather than treating an empty authored outline as a decoding
error.

| Original body workflow | Observed scope before the later CHM/navigation build |
| --- | --- |
| B04 large Markdown | Actual body and small continuous scroll; first canvas draw measured separately. |
| B17 reflow EPUB | Body search result, Single/Two/Continuous transitions, source visible in the resulting spread and small continuous scroll. Finite pages can start earlier than the searched heading. |
| B13 MOBI | Cover-to-body scroll, wide/narrow prose rewrap, Single/Two/Continuous, actual search hit. Empty authored navigation independently matched the original. |
| B25 large TXT | Deep restored body, complete line count, search and detected Contents, changed-width window zoom, Single/Two/Continuous and forward spread progress. |
| B05 CHM | Body topic 50 and translated continuous-scroll pixels; narrow source column failed reading-quality acceptance and prompted the fixes above. |
| Fixed EPUB, PDF and comics | Authored geometry and painted content plus navigation samples; they are not prose-reflow tests. |

Exact binary identities, final changed-path GUI results and measurement conditions
are retained with the [performance report](LARGE_TEXT_PERFORMANCE_20261010.md).
Instrumented frame-by-frame drag flicker, physical trackpad smoothness, every page and
macOS 13 hardware are not certified by this sampled audit.

### Final changed-path observations

The canonical final executable is `01FBCDA3-F018-3BCF-BB99-4F922CDC913E`, with
engine `49396624-5425-38E7-844A-A15C1A76C650`. Both are present in the loaded
process. The packaged reader script exactly matches the checked source. The
final normal app opened the original CHM and MOBI through the native picker.

| Actual original-book check | Observed result |
| --- | --- |
| CHM topic 50, wide and narrow windows | Reader typography and prose rewrap; the former Chinese hard-wrap separator no longer paints a space. |
| CHM small continuous scroll | Scrollbar moves from 0 to 0.0408121 while topic 50 remains active. |
| CHM Single Page and Right key | Topic stays 50; painted text changes and horizontal progress advances. |
| CHM Two Pages | Two visible prose columns. A second visual defect, source-indent splitting the decorated title, was fixed and checked again in the final build: the title is whole and centered within the column. |
| CHM Find | Three original matches; selecting another result reaches topic 56. Final title normalization retains the same three matches and topic-50 highlighting. |
| MOBI Contents | Six detected entries, matching five chapter-heading lines plus the independent second-part heading. Final-build selection of the second part displays its actual body text. |
| MOBI chapter destination and modes | Chapter 6 is visible after its Contents jump, at single page 40/435 and in the right side of spread 45–46/504; Right advances to 47–48/504. Continuous restores that source passage. |
| Large Markdown actual edge resize | In the preceding build with unchanged native reading owners, a real edge gesture changes width from 1730 to 1422 pixels. The immediate capture retains preceding painted text; settled text rewraps the same top passage. Reverse attempts with unchanged dimensions are excluded. |

The source gate passed 923 Swift tests (98 core, 825 app), 17 packaging checks
and three reader-script syntax checks before the final source-line and title
corrections. After those changes, the affected checks passed: 99 core tests,
136 browser/markup tests after soft-break normalization, the new title case and
49 browser reading tests after title normalization. These overlapping suites
are separate receipts, not an invented fresh full-suite total.

All 25 originals were rechecked after the final GUI observations and retain
their inventoried size, modification time and SHA-256. The local receipts are in
`build/validation-predictive-reader-20261010`. The real edge capture establishes
sampled painted continuity, not every-frame absence of flicker. Interface-capture
timeouts during the follow-up sessions have retained idle-main-thread samples;
normal Quit and final loading restored observation, without establishing their
cause or treating missing observations as passes.

### User manual resize feedback (2026-10-11)

The user completed the requested manual window-edge drag check for the normal
app with the original 20,652,922-byte Markdown and reported:
“未看到闪屏或正文消失”. This passes the visible flashing/body-disappearance
check for that reported workflow. The reply does not independently identify
the loaded executable, so this feedback is not assigned to a specific build UUID.
It supplements the captured resize observations above; instrumented every-frame
flicker and physical trackpad smoothness remain unmeasured.

## Candidate 737 fixed EPUB acceptance

The loaded optimized **737** candidate adds fixed-layout XHTML EPUB support through the existing MuPDF handler. It honors package and spine layout declarations, retains each authored viewport as one clipped canvas with publisher CSS, and avoids loading unseen canvases merely to count or zoom a fixed book. Six new regressions cover geometry, mixed reflow, invalid viewports, conflicting declarations, lazy chapter access and actual image/positioned-box pixels. The complete **737-test gate (91 core, 646 app), zero failures or skips**, passes with 2,346 unchanged captured inputs and the exact signed 6EE engine; the canonical build cache now contains that same tested engine. The actual 53.8 MiB application passes first/middle/last painting on an owned 80,118,454-byte, 337-chapter fixed EPUB, hides reflow controls, and passes Contents filtering, empty feedback, clearing and result navigation. Closing/reopening restores its ending at chapter 337, page 1/1 and Fit Page with Next disabled. Original and clone bytes and metadata remain unchanged. Three old app copies and four native copies were removed after verified recovery, totaling 345,208,038 logical bytes; physical APFS reclamation is unknown. This accepts the sampled XHTML canvases and recorded workflows, without accepting every EPUB, arbitrary fixed-layout CSS/SVG, IME/VoiceOver, macOS 13 runtime or broad performance budgets. See the fixed EPUB evidence (internal record retained locally).

The unchanged loaded optimized **737** candidate also passes a complex reflow EPUB Contents and reopening workflow. On one owned 13,127,784-byte book with 273 chapters and 2,243 NCX entries, every author title, URI, chapter mapping, order and hierarchy is independently checked against source; 89 adjacent chapter reversals make outline order distinct from spine order. Actual filtering retains three ancestors and navigates to an internal heading at chapter 205/page 14 of 18; 17→18 pt moves it to page 16 of 20 and reactivation still paints the title. Empty feedback and clearing retain the position, and a cross-chapter filtered jump returns to the original fragment. Document reopening and normal process quit/relaunch through Home's recent books restore chapter 205/page 16 of 20, Fit Page and 18 pt; sampled body images match the pre-close capture. All 2,346 captured inputs, application identity and original/clone bytes and metadata remain unchanged. No app/engine copy or dependency was added. This accepts that book's source outline and the recorded GUI workflow, without accepting every chapter body, all EPUBs, repeated-spine ambiguity, exact continuous anchors, accessibility, performance budgets or macOS 13 runtime. See the complex EPUB evidence (internal record retained locally).

## Findings that still guide acceptance

### Window-sized reading modes (2026-10-10)

The reader now offers Single Page, Continuous and Two Pages through the same
reading menu for native pages, plain text and browser documents. Reflow EPUB,
MOBI, HTML and Markdown use the actual reading viewport for text layout; TXT
uses native TextKit viewport layout. Facing reflow pages each use half the
available width. Fixed-layout EPUB, PDF and image pages retain their source
geometry while fitting and scrolling within the window.

Continuous native reflow uses MuPDF's natural chapter height, with no page-top,
page-bottom or inter-page paper gaps. Each chapter is one variable-height canvas;
the existing raster owner renders viewport-sized regions without a whole-chapter
preview. Accessibility text and link hints follow the visible region. Height-only
window changes resize the viewport without rewrapping the native text.

Reader themes override publisher text and background colors, including author
`!important` declarations, while retaining layout and images. Resizing retains
the source reading position. During native window live resize, reflow pages retain
the painted layout; one final reflow uses the gesture-start passage after release.
Find queries survive viewport changes and recount unpainted chapters. Bare
horizontal arrow keys turn reading pages;
text selection modes and modified selection keys retain their own behavior.
Native page replacement transfers existing reader keyboard focus without
taking focus from an input control. Browser continuous scrolling retains native
scroll behavior within the current document or CHM topic.

The final natural-layout and position-handoff source gate passed 898 Swift tests (94 core, 804 app), plus 17
packaging checks and reader-script syntax checks. This includes source-position, theme pixels, single/facing
boundaries, repeated keyboard input and selection regressions. Actual corpus
window observations and loaded binary identity are recorded separately in the
local reading-mode evidence; these checks do not establish Books.app performance
parity, every-page fidelity or physical trackpad smoothness.

The loaded optimized candidate also paints the original large Markdown sentence
across the former page boundary with normal line spacing. Real EPUB and MOBI
windows use natural chapter height and small scrolling within the same chapter;
the EPUB passage remains at the viewport top after native window zoom reflows it.
The initial full-chapter accessibility JSON allocation was replaced with visible
region extraction, retaining source glyph geometry, spaces and ligatures.
Large Markdown startup and resident memory still need improvement; this is not
acceptance of a whole-app performance budget.

The subsequent large-text owner fix avoids whole-chapter shaping for source
restoration and visible-region capture. A controlled 20.65 MB Markdown native
restore fell from 2.866 s to 0.341 s, with process peak RSS through that stage
falling from 2.36 GB to 0.53 GB. These are scoped single-run measurements;
see [large-text performance evidence](LARGE_TEXT_PERFORMANCE_20261010.md).
The EPUB regression now exercises repeated Single/Two/Continuous transitions near
the body chapter's end and same-count width reflows with native smart scrollers.
It checks the restored unique word in the current rendered viewport and retains
the body chapter, rather than accepting an old bitmap or estimated page height.
The optimized build `F626ED31` was then checked in real EPUB, 20.65 MB Markdown
and 51.61 MB TXT windows. It was loaded into the canonical local application,
where EPUB search and Single/Two/Continuous transitions retained the current
visible body paragraph. Loaded executable and engine identities are recorded
separately; the previous application is retained in a recoverable local backup.
Finite Fit Page modes can show an earlier page start after reflow, so subsequent
mode transitions compare the current viewport's source, not a heading that was
visible before several earlier transitions. Physical trackpad frame rate and
manual window-drag flicker remain unmeasured.

The subsequent final large-text build `DF095914` passed 907 Swift tests (95 core,
812 app), 17 packaging checks and reader-script syntax checks. Fresh-process
checks on the original 20.65 MB Markdown observed first readable body at 8.746 s
and peak physical footprint of 0.807 GB, compared with 12.707 s and 3.076 GB in
the previous normal build. The original 51.61 MB TXT showed body at 1.054 s;
its 0.452 GB peak is similar to the old 0.432 GB, with no claimed memory reduction.
Its complete 340,268-line index was observed by 6.336 s, an upper-bound observation.
The final candidate also exercised the reported Markdown gap, EPUB search and
Single/Two/Continuous transitions, MOBI cover-to-body scrolling, and large TXT
search, detected chapter navigation and source-preserving window zoom.
All 25 originals match the inventory's size, modification time and SHA-256.

That same final main UUID and MuPDF UUID were verified in the running canonical
`dist/Sumra.app` after recoverable replacement of `F626ED31`. Real normal-app
Markdown scrolling and width reflow retained the body passage; screenshots show
the old text painted while replacement layout is pending. Automated final edge
drags that left window dimensions unchanged do not count as resize evidence.
An earlier actual edge resize exercises unchanged live-resize owners; final
native accessibility window zooms verify changed-width reflow. Fast manual
drag frame-by-frame flicker and physical trackpad smoothness remain unmeasured.
The [performance report](LARGE_TEXT_PERFORMANCE_20261010.md) retains exact
measurement conditions, receipt references and remaining whole-chapter costs.

- Large TXT position restoration needed native TextKit 2 and width-change handling; old whole-document layout probes had main-thread stalls. Current real-window distant scrolling, font changes and relaunch still need broader checks.
- Solid archive pages can reopen quickly after a decoded page is cached, while first unseen middle/late seeks retain decompression cost. Measure painted destination and process memory, not just scrollbar movement.
- Reflow EPUB startup uses a chapter table and background publication with stable page identity; initial readiness is not complete pagination or first-pixel timing. Publisher fixed layout and late chapter publication require visual and position checks.
- Automatic now routes large/dense Markdown through the existing MuPDF path, while explicit Compatibility and ordinary HTML/CHM retain WebKit. Native font zoom performs text reflow. Earlier browser-cap failures retain their historical scope; current native tail and typography receipts still do not complete the source-range, selection, compatibility, resource and whole-app performance matrix. Full HTML/CSS compatibility belongs to the explicit browser route; the rejected scale prototype remains outside product source. See the [approved renderer decision](MARKDOWN_RENDERER_DECISION.md).
- Large-document/browser interaction samples, including 100% Find as well as zoom workflows, recorded substantial process-group memory. Prior RSS numbers and native API heap reductions are scoped observations, not whole-app budgets or upstream comparisons.

The [reader source](../Sources/Sumra) and [app tests](../Tests/SumraAppTests) contain the maintained implementation and regression boundaries. Further acceptance should use the original corpus on the loaded app, record exact input and binary identity internally, inspect visible output and independent file contents, and state which paths were **NOT_EXERCISED**. Local historical evidence is retained outside the exported docs tree.
