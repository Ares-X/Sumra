# SyncTeX editor integration

Sumra supports inverse search from a PDF to its source and forward search from an
editor source position to the PDF. Compile with SyncTeX enabled and keep the
`.synctex` or `.synctex.gz` index beside the output PDF.

Editors invoke forward search through the macOS URL handler:

```text
sumra://synctex?pdf=<encoded absolute file URL>&source=<encoded absolute file URL>&line=42&column=0
```

`line` is one-based. `column` is optional and defaults to zero (unspecified); when
provided, it is the source column passed to the SyncTeX parser. Each `pdf` and
`source` value must be an absolute local `file:` URL, encoded as a URL query-item
value. Encode both levels: first the file URL, then that URL as the query value.
Use a URL builder rather than concatenating paths containing `&`, `#`, `%`, spaces
or Unicode. For example, an editor adapter in Swift can construct and open the
request with system APIs:

```swift
var url = URLComponents()
url.scheme = "sumra"
url.host = "synctex"
url.queryItems = [
    URLQueryItem(name: "pdf", value: pdfFileURL.absoluteString),
    URLQueryItem(name: "source", value: sourceFileURL.absoluteString),
    URLQueryItem(name: "line", value: String(sourceLine)),
    URLQueryItem(name: "column", value: String(sourceColumn))
]
NSWorkspace.shared.open(url.url!)
```

macOS delivers the URL to Sumra's existing document-open callback. Sumra resolves
the source line through its bundled SyncTeX parser and activates an existing
window for the same PDF, including a symlink to that PDF. When several windows
show it, the active window takes precedence. The window reloads the compiled PDF
and scrolls to the source location using the replacement PDF's page geometry.
Existing unsaved editing protection still applies. A new PDF opens in the empty
reader or a new window. A newer request for the same PDF supersedes a query still
being parsed. The regular file watcher also reloads changed PDFs independently
of editor requests.

A bundled Sumra app must have been registered with Launch Services for the `sumra`
scheme to resolve. A bare SwiftPM executable does not register a URL handler.
Missing or malformed indices and unavailable destination pages produce a SyncTeX
error dialog. Page boxes and coordinate conversion come from the opened MuPDF
document through its normal authentication and reload path; forward search does
not open a second PDF parser. A stale index naming a missing page is rejected.
Legacy `.pdfsync` forward search is not implemented. Requests only read
local document/index files and navigate the GUI; they do not invoke an editor or
execute URL content.

Focused validation: `swift test --filter 'SyncTeXForwardTests|SynchronizerTests'`
after building the native engines. Unit tests cover URL decoding, rejected remote
and malformed input, PDF window selection, plain/gzip indices, and reloading the
replacement PDF's geometry. Actual delivery from an installed editor through
Launch Services remains a separate GUI integration check.
