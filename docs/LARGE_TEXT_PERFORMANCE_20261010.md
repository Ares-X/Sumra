# Large text performance investigation (2026-10-10)

## Final pagination follow-up (October 11)

The loaded release candidate `0DC4E5D7-1A46-3AF2-83D3-4746BA29F0CE`
was exercised with both unchanged original Markdown books through the native
file picker on an M3 Max running macOS 27.0.1. Timings below come from application
owner events, rather than time spent opening the chooser.

| Actual GUI workflow | B04, 20.65 MB | B02, 14.17 MB |
| --- | ---: | ---: |
| First completed continuous layout | 1.922 s | 0.944 s |
| Source-open entry to first canvas draw | 2.637 s | 1.601 s |
| Continuous to Single Page layout | 0.561 s | 0.405 s |
| Two Pages layout | 0.634 s | 0.418 s |
| Return to continuous layout | 0.551 s | 0.402 s |
| Completed search matches | 336 | 47 |

Each initial open and each mode change needed one native layout. Actual Single
and Two Page turns, continuous scrolling, Find Next, Contents destinations and
fresh-process reopening passed. Reopening restored the same visible source
excerpt and scrollbar position. These observations supplement the earlier
corpus acceptance; they do not replace its build-specific receipts.

The existing MuPDF layout retains parsed HTML and CSS across reading modes.
Continuous flow removes vertical paper margins at the layout owner rather than
changing the stylesheet. Font width and actual fallback-font height metrics are
measured together and reused; ordinary uniform LTR lines avoid the unused bidi
reorder allocation. Initial pagination uses the measured target viewport,
including the selected scrollbar behavior. This follows the existing Sumatra
and MuPDF ownership model without introducing another parser or index.

A separate mode-handoff defect rendered a natural-height chapter as a full
bitmap while the new paged mode was pending. Mounted surfaces now retain their
own layout mode, and asynchronous style work publishes the mode it actually
laid out. B04's Single Page sample is 454.5 MiB physical footprint with a
782 MiB lifetime peak, compared with the reproduced faulty handoff's 3 GiB peak.
After additionally exercising Two Pages and returning to continuous reading,
the B04 process is 705.4 MiB with a 1.5 GiB lifetime peak. B02's corresponding
mode sample is 404 MiB with an 804 MiB peak. These are different workflow points;
the initial Single sample does not imply all reading stays below 782 MiB.

In a separate fixed-width native probe, B04 mode changes fell from
1.90–1.93 s to 0.20–0.21 s. Actual GUI mode changes also change width and remain
around half a second. First layout still parses and lays out the large chapter;
it is not instantaneous and no measured Windows Sumatra timing parity is claimed.
Earlier results below document preceding builds. Private captures and content-free
logs remain under
`build/validation-other-format-acceptance-20261011/markdown-pagination-20261011`.

## October 11 changed-owner findings

A real 20.65 MB Markdown Continuous→Single transition exposed a whole-chapter
accessibility extraction while tiling metadata was temporarily absent. The
sampled old process peaked at 20.9 GB physical footprint and failed to paint a
usable finite page. Reflow accessibility now always intersects the actual
visible rectangle with page bounds, independently of tile metadata. Six mounted
transition/selection regressions pass. The canonical app subsequently paints
Single and Two Page turns; its recorded finite-reading footprint is 1.6 GB with
a 3.2 GB peak, and a fresh continuous reopen is 515 MB with a 755 MB peak.
These are distinct process conditions, not a universal memory budget.

A separate Contents destination path had discarded its existing viewport before
capturing a source passage, shaping the entire natural-height chapter. That path
now passes the viewport to the existing region extraction; no new index, cache
or retry is introduced. Eight focused source-position/link checks pass. In final
main `C0630A46`, a fresh original B04 mouse jump shows the correct heading within
a 984 ms GUI observation, compared with the earlier 2.84 s event-to-scroll trace.
The measurements are not a controlled timing pair. Current physical footprint
is 530 MB with an 843 MB peak after Contents navigation; same-entry reactivation
and fresh-process source/scroll restoration also pass.

EPUB Find now uses the existing parsed HTML/CSS flow to reject impossible
chapters before glyph layout. Exact matching, options and geometry still use
the authoritative glyph search. The immediately following count reuses that
Find's proven-negative chapters; changed queries/reflow use fresh proofs.
For original B22 (1,052 chapters), controlled native Find+count falls from
23.286 s to 11.737 s with the same exact count, avoiding the repeated negative
scan. The separate find-only measurement improves 12.818→11.454 s. Parsing/CSS
traversal remains substantial; this does not make the search instantaneous.

In loaded `4D73AF77` / `C860B4AF`, the original wrapped query is observed
complete at 24.886 s and Find Next reaches the same unique wrapped match.
That is an observation upper bound. Sidebar/layout conditions differ from the
earlier GUI observations (34.256 s first hit, 40.126 s completed count), so no
controlled GUI percentage improvement is inferred. Native and GUI timing
receipts remain separate in `build/validation-epub-search-candidate-20261011`
and `build/validation-other-format-acceptance-20261011`.

Original-file integrity and source-preserving reopening were checked across
the complete corpus. The [current workflow record](BOOK_CORPUS_ACCEPTANCE.md)
also distinguishes delayed destination resolution from a falsely diagnosed
Contents click failure. At that earlier build, whole-chapter finite pagination
still cost seconds and could use gigabytes; the pagination follow-up above
supersedes those mode-switch observations. Books.app or Sumatra timing parity
was not established.

## Original-book Find and startup follow-up (2026-10-11)

Actual B04 Find in the normal app reproduced a separate failure after opening
had improved: searching `Spell` remained at zero visible results for more than
30 seconds. The native worker sample reached `markdown_write_hit` → `stext_at`;
the first match still requested structured text for the entire natural-height
chapter. Process physical footprint reached 3,530,428,184 bytes. Viewport bitmap
tiling had not bounded this search text extraction.

The existing laid-out search walker now passes each hit's actual flow text
extents to the native owner. Continuous Markdown shapes only that hit's
paragraph region, retaining original glyph quads. Its absolute UTF-16 source
ordinal gives the same result identity across first-hit, complete-count,
continuation and reflow calls. Finite pages retain their existing text indices.
Cancellation no longer waits for an unnecessary whole-chapter glyph extraction.

| Quiet native probe on unchanged original | B04, 20,652,922 bytes | B02, 14,167,756 bytes |
| --- | ---: | ---: |
| Completed initial 817-wide layout | 1.974849 s | 0.963712 s |
| First `Spell` hit | 0.009165 s | 0.057195 s |
| Complete hit geometry/count | 336 / 2.689935 s | 47 / 1.715516 s |
| Process peak RSS through search/cancellation | 584,499,200 bytes | 431,456,256 bytes |
| Return after cancellation requested at 50 ms | 0.051789 s | 0.050638 s |

These are separate native-process observations. They are not GUI first-result
times, and RSS is not the macOS app physical-footprint measurement above.
First-hit rendering also needs its decoder actor: queuing complete-count work
immediately after selecting a hit delayed navigation and drawing. The canvas
now starts that count only after the current selected highlight has actually
painted in the visible viewport, including a new query on an already-rendered
page. Its test covers both paged and continuous surfaces and a distant hit.

A fresh normal-app run also exposed a startup lifecycle race: SwiftUI supplied
an 85-point initial proposal before the window's actual 1178-point reader area.
The large chapter laid out at both widths before its first paint. Preparation
now receives a one-time measurement of the mounted AppKit reader area after
pending window layout; no guessed width or delay is used. The mounted regression
changes a transient 100-point window to 800 points before preparation and verifies
the delivered size. Shown, smart and hidden scrollbar cases still require one
native layout matching the actual clip width. Later resizing remains owned by
the existing reader viewport and source-restoration path.

Receipts are in `build/validation-format-workflows-20261011` and
`build/validation-selected-match-paint-20261011`. Native first layout still
includes whole-chapter parsing and layout; this change does not make a large
single-chapter Markdown instant or establish a Windows Sumatra timing comparison.

### Subsequent prose spacing correction

The original MOBI screenshot exposed an additional layout gap: repeated hard
breaks and full-width whitespace still consumed ordinary text rows during reflow.
Reader reflow now compacts those empty rows and normal text-only empty paragraphs
at the MuPDF layout owner while retaining source identities. Preformatted text,
tables, images, explicit page breaks and fixed EPUB retain their layout. Recognized
CHM prose receives a compact gap without changing DOM text or Find offsets.
Native and WebKit geometry/search/source-restoration checks pass separately;
actual loaded-app observations are recorded in the corpus acceptance report.
This correction is separate from the timing measurements below.

The subsequently loaded executable `B9AC7AE7-DC70-3707-A43A-5E575B50CA27`
with engine `0E03A5D0-16ED-3B5F-927D-361729821423` also carries the native
ebook source-position and Home startup handoff corrections. Original B13
reopening restored its supplied passage before searching; the single, spread
and continuous mode checks completed with that passage visible. A fresh Home
process reopened B04, completed its 336 matches and visibly navigated the next
result. These are final functional checks, not replacements for the measured
timings or memory values below. Original-book hashes remain unchanged.

### Measured integrated app observations (`68CA2284`)

The integrated executable `68CA2284-C9A3-3B78-9A66-69C8B84F0186` and engine
`C9A795E7-1C54-32CD-A8C2-7D287E72D59E` were loaded from `dist/Sumra.app`.
Fresh Home processes opened B04 and B25 through the native picker. No build,
tests or profiler ran during these measurements; a content-free log stream and
0.25-second process-footprint sampler recorded the results.

| Measured original-book observation | Result |
| --- | ---: |
| B04 completed initial layout at actual 1178-point width | 1.904713 s, one layout before first paint |
| B04 source-open entry to first ready canvas draw | 2.494779 s |
| B04 Find request to selected visible highlight paint | 0.168436 s |
| B04 completed `Spell` matches | 336; Find Next reaches the next actual passage |
| B04 kernel lifetime peak physical footprint through opening/search | 781,076,016 bytes |
| B04 later physical footprint after search | 441,026,096 bytes |
| B02 later in the B04 process | 47 completed matches; Find Next changes the actual passage |
| B25 confirming Open to first observed body | 1.415 s, GUI observation upper bound |
| B25 completed line index and chapter-search matches | 340,268 lines; 3 matches |
| B25 fresh-process kernel lifetime peak through opening/search | 488,965,368 bytes |
| B25 later physical footprint after search | 228,836,624 bytes |

The source-open and Find timings begin at the application owner's logged event,
not launch or opening the file chooser. B04's visible highlight was independently
checked in the first-result capture before complete counting finished. Both
Markdown searches completed and navigated subsequent results. B25 filtered
Contents produced three matching entries; choosing one reached its chapter
around line 194678, small scrolling advanced to 194681, Single Page advanced
to 194710, and Two Pages advanced to 194727. AX exposes the visible portion of
the virtual Contents list: a snapshot row count is not a total chapter count.
The previous opening/line-index measurements retain their own build and method;
these numbers are not substituted into a synthetic speedup ratio.

Final-build B22 also retained its selected `马尾拂尘` result through Single,
Two and Continuous modes and completed at 1/1. Its actual two-column screenshot
contains the visible orange result. The final `.rar` fixture reopened with its
nested Contents, jumped to page 3 and advanced to page 4. The build's bundle
checks passed for every embedded Mach-O's arm64 slice, minimum macOS version
and private dependency paths, and strict deep signature verification passed.
Actual macOS 13 execution remains unexercised on this macOS 27 machine.
All 25 original books still match inventory size, modification time and SHA-256.

The later normal executable `4FA3A3AB-1460-3B09-97EC-C6285370D102` loads that
same engine and adds the TXT prose/heading correction. Actual B25 Contents
no longer offers the offending prose fragment; legitimate numbered and
compact titles still navigate to their original lines. B13 retains its six
detected entries and second-part destination. These are workflow checks,
without substituting new timing or memory measurements for the table above.
The final integrity receipt is `latest-heading-original-integrity.json`.

Continuous scrolling does not require expensive whole-document work. Sumatra
supports continuous scrolling while its current MuPDF route retains finite-height pages
(`EngineMupdf.cpp:4519–4522`), caches extracted text by chapter and page
(`EngineBase.cpp:1047–1110`), and renders visible bitmap tiles (`RenderCache.cpp`).
Sumra's seamless body flow retains the same renderer, but its natural-height
page contains an entire chapter. Sumra incorrectly continued to shape and extract
that entire page even when an interaction needed one reading position. This is
an implementation error in the size of the work unit, not an inherent cost of
continuous reading. Viewport bitmap tiles did not bound the separate text work.
The loaded large-Markdown sample
confirmed the worker in `Pages.relayout` → `NativeFile.position(for:)` →
`lf_html_anchor_position`; the main thread was idle during that sample.

## Changes at the existing owners

- Source-to-position lookup finds the existing laid-out flow and draws only its
  containing paragraph, then filters the requested source cluster before
  structured-text extraction. Complete ligature and
  combining-character clusters retain MuPDF's original coordinates and parts.
- The existing native passage lookup retains one resolved result, invalidated
  before reflow. Recording a just-resolved position no longer repeats the same
  source lookup.
- Reflow resolves the current passage before requesting a transient layout
  bookmark. A resolved Markdown passage no longer triggers an unused
  whole-chapter structured-text extraction. Initial opening and queued style
  requests carry their actual viewport through position capture and restoration;
  a nil source at an artwork or margin still uses the existing bookmark path.
- Scrolling captures a Markdown passage from the actual visible page region.
  MuPDF's existing draw groups skip paragraphs outside the region before shaping.
  Actual fallback-font ascender/descender extents preserve partially visible
  boundary lines. It does not build whole-chapter text to remember the viewport.
  Finite paged layout retains the original page clipping, so glyphs touching a
  neighboring page cannot become the current page's reading anchor.
- Reading-mode changes capture the old viewport before replacing its surface,
  and layout restoration uses its stable chapter bookmark before a flat page
  projection. This also fixes an observed paginated-to-continuous chapter jump.
  Mounting a replacement reflow surface no longer overwrites the style owner's
  restored destination with a captured old pagination point.
- Position requests wait for the current layout's measured geometry and rendered
  page. A queued scroll callback previously accepted an old chapter measurement,
  then cleared it while configuring the new layout and consumed the request at
  an estimated finite height. A second smart-scroller width reflow could therefore
  jump to the next chapter. Paged views likewise retained an old bitmap while
  rendering new geometry; that bitmap is no longer treated as position readiness.
  Cancelled native reflows publish their completed revision through the next
  style task, even when the requested style already matches the native owner.
- The layout owner publishes the already-measured native bounds as the next
  geometry estimate. Resetting a natural chapter to one viewport high caused
  smart-scroller width changes to repeatedly reflow the large Markdown book.
  Native tiles retain the preceding painted generation until replacement tiles
  are ready; live window resize retains the gesture-start layout and source.

## Controlled native measurement

The same unmodified 20,652,922-byte local Markdown input was tested in separate
processes with the previous and updated engines. Both captured a source glyph in
a 620×400 paged layout, then requested a 620-wide natural layout and restored that
glyph. Source identity and the resulting exact rectangle matched. These are
single-run observations, not application startup benchmarks.

| Observation | Previous engine | Updated engine |
| --- | ---: | ---: |
| Source restoration call, including lazy natural layout | 2.866 s | 0.341 s |
| Process peak RSS through that call | 2,362,736,640 bytes | 527,892,480 bytes |

The intermediate filtered-device implementation still replayed the entire
chapter: a subsequent viewport capture took 1.776 s. The final drawing-owner
implementation captured the identical visible source and rectangle in 0.000704 s
(0.70 ms), with peak RSS of 528,023,552 bytes through that stage.

The layout-request calls themselves defer work; their short duration is not
layout completion. Evidence and the isolated probe remain in the local
`build/validation-reading-modes-20261010` directory. No local book is exported.

Whole-chapter HTML parsing and initial layout still cost time and memory.
Natural HTML rendering draws visible regions directly, while finite documents
retain the existing display-list path. Source-flow lookup scans existing flow nodes; one very long
paragraph is still replayed as one paragraph. This batch does not establish
Books.app responsiveness or eliminate all work proportional to chapter length.

## First-layout follow-up and mature implementation coverage

The pinned Sumatra source is `012d997f6a3a5c5c97b878e1a340db3bffde8c0e`.
Its current Markdown route always uses MuPDF/cmark (`EngineCreate.cpp:286–290`).
The parser feeds the complete input, finishes the AST and generates HTML
(`ext/mupdf/source/html/md.c:120–124`); the HTML layout call passes no restart
boundary (`html-layout.c:3272`). `EngineMupdf.cpp:4940–4966` defers unresolved
chapters for multi-chapter EPUB, but a single-chapter Markdown still counts its
pages on opening. This source inspection does not establish Sumatra's elapsed
time on the user's book; no Windows runtime comparison was performed.

Sumra already uses visible-region native rendering, reusable display data and
bitmap caches, cancellation of obsolete work, and retention of painted tiles
during replacement. Sumatra's finite-page predictive render chain
(`DisplayModel.cpp:2332–2372`, `RenderCache.cpp:792–841`) renders likely
neighboring pages one at a time, anchored to a visible page. The predictive
follow-up below implements that missing behavior in Sumra's existing cache
owners. It does not remove the initial whole-chapter Markdown layout. MuPDF already
compares the applied CSS, and width-only relayout reuses the parsed HTML;
neither a proposed duplicate parse nor redundant identical CSS invalidation was
confirmed in the current deferred-open path.

Content-free diagnostics on the original 20,652,922-byte Markdown showed an
819-wide initial layout taking 1.922 seconds, followed by an 804-wide layout
taking another 0.660 seconds before the correct-width body was painted. The
scrollbar had appeared only after the tall native canvas was mounted. These are
native-call measurements in the instrumented release, not comparable replacements
for the earlier Open-to-observed-body timings.

The first-layout fix uses AppKit's content-size calculation before native
preparation, then publishes the already-measured native chapter bounds to the existing canvas. The scroll
owner configures its actual canvas before publishing the clip size. Previously,
an automatic legacy scrollbar briefly hid while the document canvas was still
empty and published the outer width. The new mounted-window regression requires
one native layout for shown, smart and hidden scrollbar modes, with the final
native width matching the actual clip. The reading surface retains its existing
lifecycle; document identity and cancellation checks still precede publication.

A fresh canonical release process (`7E6D3977-1253-3D5B-A605-6792DFD63846`,
PID 56702), Home in List mode and the original B04 file selected in the native
picker, recorded exactly one 804-wide native layout before interaction:
1.932399 seconds. Its first ready draw was recorded 2.737462 seconds after Open.
The separately captured readable body was observed at 9.467 seconds; that sparse
GUI observation is an upper bound, not the first draw time. No build, test or
profiler ran during the measurement. Kernel lifetime peak physical footprint was
793,429,624 bytes; idle footprint was 425,248,328 bytes about 245.7 seconds after
Open. These are single-run results. The newer draw timestamp must not be divided
by the older 8.746-second accessibility observation to claim a speed ratio.
The eliminated extra native layout cost 0.660 seconds in the instrumented
baseline; whole-chapter layout still takes about 1.93 seconds on this input.

The source gate passes 908 Swift tests (95 core, 813 app), 17 packaging checks
and reader JavaScript syntax checks. The new regression covers an actual mounted
window in all three scrollbar modes. A trial that withheld the reading surface
failed navigation tests and was removed; the accepted implementation retains the
existing surface lifecycle. All 25 original files retain their inventoried size,
modification time and SHA-256. Receipts for this follow-up are in
`build/validation-first-layout-20261010`, including
`baseline-instrumented-events.json`, `final-B04-measurement.json`,
`check-source-final.log` and `corpus-integrity.json`.

An apparent black body in the computer-use image display was investigated and
withdrawn: direct pixel analysis of the saved original captures finds body text
throughout both images. Their pixel difference is confined to the pointer area,
not a cleared reading surface. No speculative viewport-slice change or temporary
per-draw diagnostic remains in the accepted source. Automated edge drags that do
not change window dimensions remain excluded from resize evidence.

The final rebuild reproduced the measured executable UUID and unchanged MuPDF
bytes, then both UUIDs were verified in canonical process 99865. In this process,
macOS Window > Move & Resize > Left changed the window from 3456 pixels wide to
1730. The pending-layout capture retains body pixels; the ready capture rewraps
the same passage, and subsequent continuous scrolling changes its visible text.
The original B17 EPUB returns two matches for `第一百六十五章`; selecting its
body result reaches that chapter. Original B25 TXT finishes its 340,268-line
index, reaches line 194683 and preserves that source line when macOS Return to
Previous Size restores the window. These targeted checks passed without a new
Documents permission prompt. `accepted-loading-and-resize.json`,
`accepted-loaded-process.txt` and the corresponding `accepted-*` captures retain
the evidence. They do not establish every-frame freedom from drag flicker.

## TXT is a different path

TXT uses TextKit 2 viewport fragments. Full-file decoding and initial text
storage remain whole-text work. The initial font and paragraph style are set on
the empty view before inserting the large string, avoiding a second full-text
attribute pass. Its existing viewport owner captures the reading position at
live-resize start and restores it after the final width change.

The source-line/chapter index finishes independently of first paint. Chapter
detection now applies its candidate expression before the grapheme-length
rejection; ordinary prose no longer pays for a full grapheme count. A retained
1,728-input parity comparison checks that recognized chapters are unchanged.
The earlier first-paint sample captured background indexing and initial text
insertion, but did not establish their exact durations or a TXT-only memory
peak. Fresh-process GUI observations below separate those measurements.

## Earlier original-book GUI measurements (`DF095914`)

The final optimized application (`DF095914-0241-3C52-87F2-79CF0C22235F`)
was measured with separate new processes, the original Books folder selected
through the native file picker, and Home in List mode. No build, tests or
profiler ran during these first-body measurements. Times run from confirming
Open to observing readable body in accessibility and screenshots; they are
observed readiness times, not instrumented first-pixel times. Memory is the
macOS process physical footprint, sampled every 0.25 seconds. The previous run
records the largest sampled value; the final run also records the kernel's
lifetime peak, which is used in the table. Values below use decimal GB.

| Original input and observation | Previous normal build `F626ED31` | Final build `DF095914` |
| --- | ---: | ---: |
| 20,652,922-byte Markdown, first readable body | 12.707 s | 8.746 s |
| Same Markdown, recorded peak physical footprint | 3.076 GB | 0.807 GB |
| Same Markdown, later idle footprint before interactions | 1.659 GB at about 42 s | 0.557 GB at about 53 s |
| 51,613,404-byte TXT, first readable body | 1.090 s | 1.054 s |
| Same TXT, recorded peak physical footprint | 0.432 GB | 0.452 GB |
| Same TXT, complete 340,268-line index first observed | 17.763 s | 6.336 s |

These are single-run observations. The Markdown body appeared about 31% sooner
and its peak footprint fell about 74%. TXT's first-body time and memory are
effectively unchanged; this batch does not claim a TXT memory reduction.
Index observations have gaps, so those times are upper bounds, not exact index
durations or an indexing speed ratio. The final TXT later settled at 0.202 GB
before Find and navigation.

Final-build GUI checks also opened the second 14.17 MB Markdown, verified that
the sentence from the reported page-gap screenshot now runs continuously, and
scrolled it across the former break. The original EPUB returned two expected
search matches and retained its body passage through Single Page, Two Pages,
Continuous and window width changes. The 17.9 MB MOBI painted its cover and
scrolled into body text and an image. The large TXT returned three independently
expected chapter search matches, navigated through its detected Contents entry,
scrolled within the passage, and retained source line 194683 after expanding and
restoring the window. All 25 original inputs retain their size, modification time
and SHA-256 from the corpus inventory. This is a targeted final-build check;
the earlier full 25-book sweep and its remaining findings retain their scope.

Window-resize screenshots show the preceding native text tiles still painted
while new-width layout is pending, followed by correctly rewrapped text at the
same source passage. A real edge resize on the earlier `CE9C` candidate changed
its window from 1852×1536 to 1442×1302 pixels; the live-resize and tile-retention
owners are unchanged in the final build. Several final automated edge drags did
not change the window dimensions and are excluded as resize evidence. Final
candidate and canonical-app accessibility window zooms did change dimensions.
These observations and the rendering regressions verify retained paint and
source restoration, but do not establish zero flicker at every frame of a fast
manual drag or physical trackpad frame rate.

The earlier source gate passed 907 Swift tests (95 core, 812 app), 17 packaging
checks and reader JavaScript syntax checks. The same main executable UUID and
MuPDF UUID `FB54F5B5-8E8F-3A43-A887-2EDF8C5CCF95` were then verified in the
running canonical `dist/Sumra.app` after recoverable replacement of `F626ED31`.
The normal app actually opened the large Markdown, continuously scrolled and
rewrapped it while retaining its body passage. Normal preferences and document
history remain in place. The previous normal application remains recoverable.

Local receipts are retained in `build/validation-large-text-resize-20261010`:
`accepted-B04-measurement.json`, `accepted-B25-measurement.json`, the corresponding
memory JSONL and GUI captures, `check-source-viewport-final.log`,
`corpus-integrity-final.json`, and `normal-promotion.json` with its loaded-process
sample. Earlier provisional measurements are labelled by their earlier build;
they are not substituted for the final numbers above.

The local app uses ad-hoc signing. Rebuilding changes its code identity and can
cause macOS to request Documents permission again. Selecting the original Books
folder through the native picker allowed all these final runs and canonical
verification without another privacy prompt. This does not guarantee that
future ad-hoc updates never prompt; no privacy database or security requirement
was modified.

Current Sumatra TXT uses MuPDF-generated HTML (`EngineCreate.cpp:333–347`,
`EngineMupdf.cpp:3914–4004`); the old `EngineTxt` route is disabled. Changing
Sumra's TXT engine is not supported by this evidence. No same-machine Sumatra
timing comparison was performed.

The [capability gap audit](SUMATRA_GAP_AUDIT_20261010.md) separately lists missing
features. Source coverage, native-call measurement, loaded GUI behavior and
whole-application performance remain distinct evidence.

## Predictive rendering and generated-Markdown follow-up

Finite continuous, single-page and spread reading now warm one likely next or
previous page in the existing page cache. Natural chapter flow warms one tile
from the next viewport in its existing 64 MiB tile cache. Prediction waits for
all visible canvases to paint, uses the scroll owner's direction at chapter
boundaries, and cancels when the viewport, document or layout changes. It does
not mount an offscreen reading view or start its accessibility and annotation
work. A speculative decoding error does not replace the visible reader with an
error; actually requesting that page retains normal error reporting.

The first painted canvas now starts deferred chapter counting. Publishing an
unpainted render result previously started that work before visible native
tiles were ready. During live resize, an unchanged frozen layout no longer
replaces each visible hosting view's root on every width update. The existing
gesture-start passage and preceding painted output remain the resize owners.

Native profiling of the original Markdown files found HTML parsing, style and
layout work. The MuPDF HTML directionality owner now handles printable ASCII
Latin left-to-right runs directly; Unicode, RTL, images and hard breaks retain
the original shaping path. Markdown with no raw HTML nodes uses cmark's
generated XHTML directly through the existing XML parser. Raw HTML retains
the HTML5 parser. Parser choice is determined by the AST, without a parse-fail
fallback. Generated footnote boolean attributes are made XML-compatible at the
cmark serializer, without rewriting user strings or attributes. Existing
entity decoding, links, source anchors and rendered pixels are preserved.

Separate processes used the same 804-wide natural layout and unchanged inputs:

| Native style and completed layout | Before this follow-up | Final engine |
| --- | ---: | ---: |
| B02, 14,167,756-byte Markdown | 1.30755 s | 0.96480 s |
| B04, 20,652,922-byte Markdown | 1.85059 s | 1.82096 s |
| B02 process peak RSS through rendering probes | 422,805,504 bytes | 406,142,976 bytes |
| B04 process peak RSS through rendering probes | 573,718,528 bytes | 573,685,760 bytes |

These are single-run native measurements, not application first-paint timings.
B02 has no raw HTML nodes and benefits from the direct generated-XML path. B04
has 6,916 raw HTML nodes, including cross-paragraph HTML, so it retains HTML5
parsing and shows only a small layout improvement, with effectively unchanged
native peak RSS. Both books retain identical full
bounds, source anchors and RGB hashes at three distant reading positions. This
does not establish instant first layout for a very large single chapter.

The staged bundle now checks every Mach-O executable and library, including
updater helpers and the private converter: each must contain arm64, declare
macOS 13 or earlier as its minimum, and resolve non-system dependencies inside
the bundle. The build has no model-specific ARM CPU target; optional newer SIMD
uses upstream runtime dispatch. The macOS 15-only Security symbol is weak
imported and availability guarded. Actual macOS 13 and M1 hardware execution
has not been exercised on this macOS 27 host.

Local evidence for this follow-up is retained in
`build/validation-predictive-reader-20261010`, including before/after native
JSON (`B02-accepted.json` and `B04-accepted.json`), patch-chain checks,
`build-release-parser-fixed.log` and the original-corpus integrity
receipt. No original book was modified.

### Follow-up application measurements and acceptance correction

The subsequent canonical release executable `23DD1508-BD9F-380B-8B73-05AB02AE9478`
and engine `49396624-5425-38E7-844A-A15C1A76C650` were loaded for these original-book
observations. Native Markdown used the actual 919-point reading width, 17-point
type, line spacing 1.6 and margin 32. First paint is the canvas draw event belonging
to that document owner, rather than an earlier document's delayed callback.

| Original input and process condition | Native completed layout | Open to actual first canvas draw |
| --- | ---: | ---: |
| B04, 20.65 MB Markdown, fresh Home process | 1.838719 s | 2.647885 s |
| B02, 14.17 MB Markdown, warm document switch | 1.044980 s | 1.758870 s |

Prediction starts 4.752 ms and 4.510 ms after those visible draws respectively;
prediction work takes 16.396 ms and 19.839 ms. B04's kernel physical-footprint peak
is 892,487,240 bytes, observed after Open; its last sampled footprint after reading
is 607,454,768 bytes. The original 51.61 MB TXT shows its restored body and complete
340,268-line count within the 1.665-second AX observation, with a kernel peak of
524,485,880 bytes. TXT has no native canvas-draw telemetry, so that readiness is an
observation upper bound. These process measurements differ in viewport and state
from earlier measurements and do not support a new before/after memory ratio.

The 25 original books were opened through the canonical app's native picker.
Opening receipts and scrollbar movement establish only those actions. Subsequent
body checks found that CHM plain-text chapters still used tiny default monospace
type and source-fixed 35-character lines. Font controls were also disabled while
publisher styles were active. The shared browser owner additionally used document
root height instead of the real window viewport to detect the end, so font changes
could jump a mid-chapter passage to the bottom. Those findings require reading
effect checks beyond the earlier opening sweep; see the current corpus report.

The browser fixes use reader typography for plain CHM, preserve text and search
offsets while visually reflowing detected source-wrapped Chinese paragraphs, and
fit HTML prose containers to the viewport. Reader font changes explicitly override
CHM author typography. End detection and resize retention use the actual viewport
and saved source anchor. Explicit CSS column width establishes the paged container
on older WebKit instead of relying only on the newer `column-count:1` behavior.

Latest-edge drag attempts that leave image dimensions unchanged remain invalid
resize evidence. Actual window zoom and tiling changes verify reflow and source
retention; physical drag frame-by-frame flicker and older macOS hardware remain
unmeasured. The later CHM/navigation build and its GUI observations are recorded
separately from the performance binary above.

### Loaded final reading-effects build

The final canonical executable is `01FBCDA3-F018-3BCF-BB99-4F922CDC913E` and the
engine remains `49396624-5425-38E7-844A-A15C1A76C650`. A fresh process sample
confirms both loaded images. The packaged `markdown.js` SHA-256 is
`94c30bdedce70440d42e25b3d829ada566402cb4f414fe3ce75f39d243f5369c`, exactly
matching source. The build is a local ad-hoc signed release build; it has not
been published or notarized. The preceding app remains recoverable.

CHM visual acceptance additionally found source hard-wrap spaces between Han
glyphs and a heavily indented decorated title splitting in a narrow spread.
The reader hides those layout separators while retaining their exact characters
in the source DOM and search index. The final original topic visibly reflows,
keeps its title whole in two columns and returns the same three Find matches.
MOBI source-line detection now handles headings separated by `<br></br>` inside
long paragraphs; the final original shows six navigable Contents entries and
actually reaches its second part. These fixes and their overlapping affected
test receipts are detailed in the corpus report.

One subsequent actual Markdown edge gesture changed the image width from 1730
to 1422 pixels in executable `8EAD61E6`, using the same native engine and
unchanged `Pages.swift` owner as this final build. The immediate post-gesture
image retains the preceding text, and the settled image rewraps the same top
passage. Other attempts whose dimensions stayed fixed remain excluded. This
adds actual edge-resize evidence without claiming every-frame flicker or
physical trackpad smoothness. No new first-paint timing or memory reduction is
inferred from these interactive checks.

The final bundle checks all nine Mach-O files for arm64, minimum macOS version
and bundled dependency resolution. Actual macOS 13/M1 execution remains
unexercised. `bundle-compatibility.json`, `final-title-loaded-process.txt`,
`corpus-integrity-final-effects.json` and the final changed-path window captures
retain the separate source, packaged, loaded and original-book evidence.

### Published Actions build (2026-10-11)

The final 0.2.2 app, source `ad996417` and executable `D5A599B0`, supersedes
the historical local builds above. Original B02/B04 first painted canvases
were observed at 1.434/2.308 seconds; first chapter layouts took 0.898/1.755
seconds, and mode layouts took 0.390–0.544 seconds. Reading sessions including
mode changes, search and Contents peaked at 968–971 MiB physical footprint.
These scopes and the actual reading/reopening checks are recorded in the
[published corpus acceptance](BOOK_CORPUS_ACCEPTANCE.md#published-022-actions-acceptance-2026-10-11).

Publication and a real 0.2.1-to-0.2.2 Sparkle installation passed with the
accepted bytes. Immediately after updating, one B04 GUI readiness observation
took 13.528 seconds with no retained reader trace explaining the delay.
Two further fresh processes, including the canonical normal app, painted the
first canvas in 2.450/2.351 seconds. The unexplained initial observation remains
in the record; no OS cause or universal timing guarantee is inferred.

### Post-update first-open investigation (2026-10-11)

A private signed diagnostic candidate adds content-free timing for source loading,
native decoding, initial viewport delivery, layout, restoration and publication.
An actual Sparkle installation from 0.2.1, followed by opening original B04,
painted its first canvas 3.032 seconds after the load request: source opening took
0.197 seconds and native layout took 1.851 seconds. The saved 100-character
passage remained visible. Physical footprint settled at 506.6 MiB, with a lifetime
peak of 760.2 MiB. A fresh-process dense accessibility-observation run and a
direct Recent Documents open also retained the original passage.

Mounted-window regression testing reproduced a separate legacy-position defect:
an old finite bookmark without a source passage published finite pages before
reflowing to the requested continuous viewport. Initial preparation now resolves
that old location and completes the requested geometry before publishing the
first canvas. If AppKit's scrollbar preference changes during that work, the
first published geometry uses the resulting viewport width. Stable viewport
inputs retain one native layout; legacy geometry or an actual width change needs
two layouts, with one publication and preserved source coordinates.

These observations do not explain the original 13.528-second first open. Its
pre-update position and reader-stage trace were not retained, so the legacy
defect cannot be assigned as its cause. The first-open investigation remains
open; non-reproduction is not a resolution, and this follow-up is not a new
public release.

### Signed initial-publication candidate (2026-10-12)

The private Actions candidate `1a0ffdcc`, executable `EC4D5E64`, was installed
through Sparkle and checked against its signed archive. The normal public
0.2.2 release remains unchanged. Fresh-process original-book runs retained the
saved 100-character passage and published the final initial geometry once:

| Original | Viewport width | Load to first canvas | Native layout | Stable footprint | Lifetime peak |
| --- | ---: | ---: | ---: | ---: | ---: |
| B04 | 1265 pt | 2.449 s | 1.845 s | 514.7 MiB | 760.7 MiB |
| B02 | 1265 pt | 1.523 s | 0.980 s | 365.9 MiB | 617.6 MiB |
| B04, restored narrow window | 770 pt | 2.517 s | 1.911 s | 502.9 MiB | 750.2 MiB |

The two wide-window runs each requested three renders before the first canvas,
compared with 25 requests in the preceding diagnostic B04 run. The narrow run
used six requests. Dense AX observations in that narrow window first found the
correct original passage at 2.693 seconds. Each run required one native layout.

Actual single-page, two-page and continuous round trips returned both books to
their original passage and scroll position. B04 mode layouts took
0.553/0.568/0.537 seconds; B02 took 0.390/0.390/0.399 seconds. The sampled mode
sessions peaked at 825.9/778.3 MiB and settled at 532.1/391.7 MiB respectively;
these are the sampled intervals, not an every-frame memory claim. The B04
two-page surface was visually inspected, and B02 exposed one/two painted page
elements in the corresponding modes.

Two initial B04 test runs restored only the generic reading record, overlooking
the authoritative `:markdown:paged` record. They are excluded from original
saved-position acceptance. Both records were then restored from the valid source
snapshot with the app closed, and the later source-match checks above passed.

The original 13.528-second measurement was first readable AX-body readiness,
not an instrumented first-paint timestamp. Its delayed AX replies and changing
page/scroll controls do not identify the historical cause. Additional local,
content-free timing now separates AX task scheduling, native region extraction
and main-thread snapshot publication from canvas drawing. Focused accessibility
regressions pass; no new public release or resolution of that anomaly is claimed.

### First-open scrollbar feedback investigation (2026-10-12)

Two fresh-process runs of signed diagnostic source `6f58ad87` used the same
original B04 passage records and restored narrow window (770 by 861 pt clip).
Continuous AX observation painted the first canvas in 2.390 seconds. Opening
without post-click AX observation painted in 3.399 seconds; native AX publication
followed the canvas by 13.606/13.076 milliseconds respectively. Native visible
text extraction and main-thread AX snapshot building each took milliseconds.
The quiet run's eventual AX check was delayed by orchestration; its native phase
timestamps, rather than that late request, determine these timings.

The quiet run exposed a real startup feedback loop: 2,925 viewport configurations
preceded its first canvas, alternating between the barless 785 by 861 pt frame
and the 770 by 846 pt clip with both legacy scrollbars. It requested 78 renders,
compared with three in the observation run. Both retained the saved passage;
physical footprint settled at 502.1/503.3 MiB and lifetime peaks were
744.2/745.4 MiB. A single comparison does not establish that AX polling causes
the difference, or assign this loop as the original 13.528-second cause.

The continuous viewport now owns its scrollbar axes: a natural width-fit canvas
uses only vertical scrolling, while custom zoom retains horizontal panning.
Mounted cells no longer reapply generic scrollbar settings to that owner.
The first-mount regression failed on the previous behavior because a needless
horizontal bar reduced reading height. Initial geometry, continuous reading,
mode-position and prediction checks pass after the change. Signed original-book
verification of this fix is pending; the historical anomaly remains open.

The signed `fe7291b8` partial fix was then checked on original B04 with the
matched quiet-open inputs: first canvas 2.424 seconds, saved passage retained,
518.6 MiB stable footprint and 765.2 MiB lifetime peak. The unwanted horizontal
footprint disappeared, but 523 viewport configurations and nine render requests
still preceded the canvas, alternating vertical-bar visibility for about
173 milliseconds. A repeat of the preceding source had painted in 2.449 seconds
with three requests, confirming that the feedback loop is intermittent.

The owner now asks AppKit to finish `NSScrollView.tile()` before deriving its
layout key from the clip; synchronous retile notifications stay inside the
existing arrangement transaction. Debug viewport flags also distinguish actual
legacy style (16), preferred legacy style (32), and autohiding (64). The affected
16 geometry, continuous reading, mode-position and prediction tests pass. This
ordering change still requires signed original-book verification and does not
resolve the historical 13.528-second record by itself.

Signed `a35c8fae` verification falsified that ordering-only fix. Matched quiet
B04 opens painted in 2.345 and 2.555 seconds and retained the saved passage.
The first run had 13 configurations/three render requests, but its repeat had
542 configurations/nine requests. Both actual and preferred scroller style
remained legacy, with AppKit autohiding enabled throughout. Stable footprints
were 516.3/501.1 MiB; lifetime peaks were 764.6/743.6 MiB. AX snapshots followed
the first run's canvas by 8.376 milliseconds. The delayed manual AX reads are
not used as open timings.

The next correction assigns legacy smart-scrollbar visibility to the existing
natural document-geometry owner. It evaluates overflow at the full viewport,
reserves vertical space when needed, and commits only that final canvas frame.
Overlay behavior and custom-zoom panning keep their existing AppKit policy.
Its full-viewport cache is invalidated when leaving that policy and reevaluated
on document measurement or window changes. Seventeen focused initial-geometry,
continuous-reading, EPUB mode-position and prediction checks pass, including
short-document scrollbar removal, resize restoration, hidden-to-smart policy
changes and custom-zoom panning. Signed original-book verification remains
pending; no historical-cause conclusion is claimed.

The `a6a0f596` candidate was built by Actions run `38158780617`. Its 181 app
file hashes match the retained source/build provenance; deep strict code-signing
and the Sparkle Ed25519 signature pass. All nine shipped Mach-O files contain
ARM64 and declare minimum macOS versions no higher than 13.0. Executable UUID:
`471B210C-BFDD-3406-9383-B3200C6BEAB1`. The ZIP SHA-256 is
`05a7cfe24a342eea143f1ac96bd478584e193892c7b2b6536df0f09f5caf5532`.
The GUI tool then reported a locked Mac, so actual original-book verification
of this candidate is still pending manual unlock. The idle legacy update
fixture and native log stream were stopped; prior traces, original-book hashes
and signed recovery archives remain retained. The public release is unchanged.

### User manual resize feedback (2026-10-11)

For the requested normal-app manual window-edge drag check on the original
20,652,922-byte Markdown, the user reported “未看到闪屏或正文消失”. The visible
flashing/body-disappearance check passes for that reported workflow. The reply
does not independently identify the loaded build, and supplies no instrumented
frame-by-frame timing or memory measurement. See the
[corpus acceptance record](BOOK_CORPUS_ACCEPTANCE.md#user-manual-resize-feedback-2026-10-11).

## Upstream performance audit while GUI access is unavailable (2026-10-12)

Source inspection, implementation and local integration checks continued while
the GUI tool reported that automatic unlock had failed. This batch compares
Sumatra `012d997f6a3a5c5c97b878e1a340db3bffde8c0e` with MuPDF
`f030eda1e472268667805f438e38cee8f1da61f8`. MuPDF upstream comparisons use the
committed source, rather than Sumra's patched dependency checkout.

### Demonstrated redundant work removed

| Owner | Previous behavior | Change and relevant evidence |
| --- | --- | --- |
| Continuous-page and natural-tile prediction, `Pages.swift` | Every change to the visible pixel rectangle cancelled an otherwise useful prediction. A predicted tile becoming visible could start a second render. | Keep predictions by document, layout and target. The visible tile joins the existing render task. A held-decoder test moves one pixel, then enters the predicted strip, and verifies that the same uncancelled task supplies the visible pixels. This follows `RenderCache.cpp:744–778` request identity and deduplication. |
| Page preheating, `Pages.swift` | Prediction requested links and image-collection landscape metadata even though it discarded the resulting page model. | Preheating requests the pixels without those unconsumed metadata results. A native HTML integration test verifies bitmap reuse and that visible rendering still supplies its links. Sumatra prediction requests bitmap rendering through `RenderCache.cpp:1278–1295` and `PageRenderService.cpp:154–156`. |
| Explicit Markdown mode changes, `ReaderState.swift` | Choosing automatic mode scanned the source on the main actor, then opening performed the same routing decision again. | The existing opening worker decides the renderer once, and publication restores that renderer's saved coordinates. Tests cover mode-specific passage/page restoration and a failed open leaving the mounted document and preference intact. The source scan applies below the 8 MiB size threshold; this finding does not explain the historical 20.65 MB book's 13.528-second open. |
| Current CHM topic search, `markdown.js` | Search excluded CHM from current-DOM reuse, refetching, decoding and parsing the topic already displayed and reflowed. | Reuse its live DOM after existing CHM path canonicalization. WebKit tests verify zero current-topic fetches, declared legacy encodings, cross-line Chinese search in reflowed text, and navigation to a sibling result. Other topics retain their existing fetch path. |

### What is upstream, platform adaptation, or custom work

PDF and EPUB decoding, chapter parsing and the core layout model use MuPDF.
Sumatra's single-chapter route calls `fz_count_pages()` during opening
(`EngineMupdf.cpp:4940–4975`); upstream HTML performs complete HTML parsing and
layout (`html-doc.c:199–208`). EPUB reuses parsed chapter HTML through
`fz_find_html` / `fz_store_html` (`epub-doc.c:454–498`). These are source facts,
not measurements showing that a Windows Sumatra build takes 13.528 seconds on
the same book. No such runtime comparison was performed.

The existing visible tile grid, retained old pixels during replacement and
direction-based adjacent-page prediction have identifiable Sumatra counterparts
in `RenderCache.cpp`. Natural chapter flow uses viewport-sized tiles to provide
the requested continuous prose without rendering an entire long chapter into a
single bitmap. TXT uses AppKit's TextKit 2 viewport layout and shared content
storage; it is a platform implementation rather than a new text layout engine.

The following Sumra changes are custom and require input-specific acceptance:

- **Automatic Markdown routing:** the 8 MiB/source-density policy responds to
  observed WebKit layout limits. It is not a Sumatra policy. The duplicated
  main-actor decision above was unnecessary and is removed.
- **Chinese CHM hard-wrap reflow:** source-text inspection and DOM paragraph
  construction implement the requested smart reflow. The current upstream CHM
  text collection does not supply this heuristic. Its original-book display
  evidence does not substitute for a fresh first-layout CPU/memory measurement.
- **Generated-Markdown XML parsing:** the fast path avoids Gumbo when generated
  Markdown contains no raw HTML, after checking the AST. The retained original
  B02 native measurement improved from 1.30755 to 0.96480 seconds; B04, with
  6,916 raw-HTML nodes, retained the ordinary parser and changed only from
  1.85059 to 1.82096 seconds. This is not a universal first-open improvement.
- **Compact flow handles and text-width caching:** the 32-bit handles trade
  pointer storage for directory lookups, and the existing width cache trades
  repeated font measurement for hash lookups. They are local patches with real
  layout consumers, not a verbatim Sumatra implementation. Their cost must be
  checked against the retained original-book measurements before broader claims.
- **Stable source anchors and regional text drawing:** added text-item and
  extracted-character fields consume memory, while serving selection, copying,
  reflow position restoration and visible-region rendering. Removing them would
  remove those existing behaviors; their cost remains part of the measured
  native layout and memory budget.

A further bounded opportunity remains: `Pages.image()` creates its MuPDF
cancellation cookie before `RasterDocument.image()` checks the whole-page bitmap
cache. A cache hit therefore still opens a library reference, resolves cookie
functions and allocates a cookie. This was not changed in this batch, and no
measurement establishes it as a major first-open cost.

The audit also checked an entity-decoding suspicion in the generated XML path.
Committed upstream Gumbo output already passes through XML entity emission;
the local path reproduces that behavior. It is not evidence of a new
Sumra-specific performance regression or the historical opening delay.

### Validation and remaining acceptance

The first two test runs exposed fixture mistakes: a replacement CHM home path
did not preserve the binary fixture's fixed field length, and an expected
opening-error test used a success-only waiting helper. Both fixture errors were
corrected without weakening the production failure behavior. The affected
32 checks then passed, including prediction, initial layout, natural rendering,
native position restoration, Markdown routing and real WebKit topic search.
Three additional EPUB mode-position and reading-mode checks passed. The release
build also passed; its executable contains ARM64 and declares minimum macOS
13.0. This does not establish runtime acceptance on macOS 13 or an M1 machine.

Receipts are in `build/validation-upstream-audit-20261012`. These are source and
local integration results. This batch has not been loaded and accepted against
the user's original books in the graphical reader; no first-open, mode-switch,
resize or memory improvement is claimed for that workflow yet. The historical
13.528-second cause remains unresolved, the public release is unchanged, and
the release goal is not complete.

All three audit agents' unused Serena/SourceKit process pairs were identified
by their session logs and stopped on completion. The root agent's now-unused
pair was also stopped. A pre-existing shared SourceKit process remains running;
unrelated projects' processes were left alone.
