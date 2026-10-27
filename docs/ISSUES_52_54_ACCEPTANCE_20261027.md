# New issue follow-up — 2026-10-27

Final delivery is recorded in
[the 0.2.21 release acceptance](RELEASE_0_2_21_ACCEPTANCE_20261027.md).

The maintainer requested that the newly opened issues be included before
publication. The five-round changes were already merged in PR 56 at
`926bc56517da675c354ba1e789f5781a072d1459`. Its draft-candidate Action
40472906352 was canceled during compilation; no 0.2.21 release or feed update
occurred. The final candidate must include the follow-up below.

| Issue | Scope | Status |
| --- | --- | --- |
| [52](https://github.com/Ares-X/Sumra/issues/52) | Asynchronous native tab close results | Fixed in PR 56. Six native close tests now pass, including mixed loaded/Home/dormant-restoration tabs. Three actual form-close regressions pass validation rejection, document replacement and takeover of an in-flight save. |
| [53](https://github.com/Ares-X/Sumra/issues/53) | TXT bookmark ordering loses UTF-16 anchors within a wrapped physical line | The existing comparison key now includes the numeric UTF-16 anchor. Four regressions pass reverse creation, both traversal directions and wraparound, Chinese/non-BMP text, legacy line-only positions and exact restore. Other bookmark formats keep their existing rules. |
| [54](https://github.com/Ares-X/Sumra/issues/54) | Lazy chapter progress aliases chapter boundaries and moves a one-page ending away from 100% | ChapterTable owns both directions of a shared page-bin mapping, with distinct chapter positions and explicit book endpoints. Footer and native seek use that owner. Boundary/ULP, no-op/forward-history, preview/commit, one-page-tail and lazy native-book tests pass. Native continuous progress remains a separate canvas fraction. |
| [55](https://github.com/Ares-X/Sumra/issues/55) | Continuing-review index and unconfirmed leads | Read as an index. The PDF digest cost, partial clipboard failure and manual-scroll Find strategy remain investigation leads; this release does not claim those unverified outcomes fixed. |

Acceptance distinguishes source/hosted AppKit tests, the loaded app and the
signed release/update. The issues remain open; no public reply or closure was
made during implementation.

`build/reader-polish-20261027/new-issues-affected.log` records 7 Core and 124 app
tests passed, zero failures/skips, covering these repairs and affected reader,
navigation and file-identity behavior. Issue 53's valid fail-before run exposed
41 failed assertions; the first test harness had not awaited command
acknowledgment, which was corrected and recorded separately. Issue 54's three
fail-before cases exposed 15 failures, including actual native seek into the
wrong chapter and truncation of the forward-history branch. The repaired
shared mapping passes all of them without eagerly paginating unread chapters.

The final release build and exact signed-app/update acceptance are still
separate delivery steps; these source and hosted results do not claim them.
