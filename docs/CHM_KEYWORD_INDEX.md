# CHM keyword navigation

Open Contents in the sidebar, then choose Index to browse a CHM's `.hhk`
keyword index. Search Index filters keyword names as you type, ignoring case
and diacritics. A keyword with one topic opens that topic directly; a keyword
with several topics lists each topic under the keyword so every destination
can be opened. Navigation uses the reader's existing topic links and history.
The Contents tab retains the `.hhc` outline, and Find retains full-text search.

The index filename comes from `#WINDOWS` (offset `0x64`), then `#SYSTEM`
(record `1`), then an archive `.hhk` entry. Index bytes use the same charset
and BOM handling as the contents outline. Repeated keyword records combine
their topic destinations; links preserve fragments and resolve archive names
without case sensitivity. Keywords without an existing topic destination do
not appear as clickable entries. An archive without a usable `.hhk` keeps the
ordinary Contents interface. Compiled binary keyword tables and cross-book
keyword links are not supported by this HTML-index path.

Focused coverage lives in `BrowserReaderTests` in `CHMReaderTests.swift`:
metadata precedence, repeated and multiple destinations, legacy encoding,
keyword filtering, and navigation through a native CHM fixture. Syntax checks
are separate from compiled tests and GUI acceptance; see the batch validation
record for the checks actually run.
