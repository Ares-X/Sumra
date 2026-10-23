# Public PDF save/reopen interoperability samples

`RealPDFInteroperabilityTests` downloads nothing. Place the following primary-source
files in a local folder and set `SUMRA_PDF_INTEROP_DIR` to opt in. Originals remain
unchanged. Native MuPDF edits a private input, writes a separate output, closes,
and reopens it through PDFKit/CoreGraphics and MuPDF. PDFKit is an independent
verification reader in these tests, not an application document-model bridge.

| Local name | Source | Scope | SHA-256 of observed download |
|---|---|---|---|
| attention.pdf | [Attention Is All You Need](https://arxiv.org/pdf/1706.03762) | 15-page multi-column paper, retained page count/text and annotations | `bdfaa68d8984f0dc02beaca527b76f207d99b666d31d1da728ee0728182df697` |
| pbc-2024-q4.pdf | [PBC 2024 Q4 monetary-policy report](https://www.pbc.gov.cn/goutongjiaoliu/113456/113469/5587716/2025022618190099812.pdf) | 59-page Chinese report | `1a642956b21b758c04ae002a2eda12e12d64a4c00ff7a2e39201e75e9ba73ea3` |
| pdf20-utf8-test.pdf | [PDF Association PDF 2.0 UTF-8 example](https://raw.githubusercontent.com/pdf-association/pdf20examples/master/pdf20-utf8-test.pdf) | UTF-8 annotation text, including supplementary characters | `a7ca717ef062df0a65e58487d26358c81424b76084a2000ca1c74b9e5776b7a1` |
| fw9.pdf | [IRS blank W-9 form](https://www.irs.gov/pub/irs-pdf/fw9.pdf) | Fill the first text field with the artificial marker `中文验收 Sumra`, save and independently inspect its value and appearance | `2d420cbb4123dcf1fb82595b2359cfbb5d81f00b9df9d359fcc7af361d093f53` |

No completed tax document or personal information is used or submitted. The
optional `SUMRA_PDF_INTEROP_EVIDENCE` directory retains `fw9-filled.pdf` and a
PDFKit-rendered PNG. The Chinese marker's saved appearance was visually checked
on this host. Download endpoints can change; tests print observed document hashes.

```sh
SUMRA_PDF_INTEROP_DIR=/absolute/path/to/samples \
SUMRA_PDF_INTEROP_EVIDENCE=/absolute/path/to/evidence \
  swift test -j 2 --filter RealPDFInteroperabilityTests
```

Generated native fixtures separately cover permissions, encryption, crop/rotation,
UserUnit, mixed page sizes, unread-page saves, signatures, journal behavior and
multi-select field parent/sibling ownership. They do not replace real complex
samples. These four public documents are a limited addition to the historical
[book corpus](BOOK_CORPUS_ACCEPTANCE.md), not proof of fidelity for every PDF,
form script, external reader or printer. MuPDF's multi-value choice setter does
not dispatch scalar keystroke/validation events. Dependent calculations now run
on page update, and scripts reading `Field.value` receive multiple selected
exports as an array of strings. The [follow-up](READER_FOLLOWUP_20261024.md)
records calculation/undo/save/reopen coverage; array assignment from scripts and
complete multi-select event APIs are not claimed.
