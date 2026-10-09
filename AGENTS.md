# Development priorities

- Prioritize working features, fast response, small binaries and simple code.
  Implement each behavior directly in its existing owner using platform or
  upstream APIs.
- Do not add defensive programming: speculative checks, duplicate validation,
  fallback chains, retries, arbitrary limits, protective wrappers or abstractions
  introduced only for hypothetical failures.
- Remove unused features, internal compatibility scaffolding, duplicate process
  gates and abstractions without an existing consumer. Do not impose test-count
  targets or turn a feature inventory into an exhaustive release gate.
- Remove existing unnecessary defensive code together with its callers, tests
  and documentation. Fix a demonstrated failure at its actual owner instead of
  adding another containment layer.
- Finish a coherent batch of functionality before running its relevant checks.
  Reuse valid evidence; repeat checks only for changed behavior or a concrete
  failure. Do not turn untested possibilities into new release requirements.
- Keep temporary artifacts minimal and retire owned, unused build and probe
  outputs after retaining the evidence needed to reproduce their results.

# Product scope

Sumra is a graphical macOS document reader. Do not add or restore a Sumra CLI,
argument parser, command-line PDF tools or silent-printing interface. File
opening, printing and document tools use the GUI and macOS document callbacks.
Build/test scripts and GUI-driven integrations with external tools remain in scope.

Use Sumatra's MuPDF document model for PDF reading and editing. Reuse the existing
NativeFile/Pages path and upstream APIs; do not expand the PDFKit-to-MuPDF object
bridge. Replace that bridge after password/permissions, actions, annotations,
forms, undo and faithful saving work on the same MuPDF document. AppKit remains
the owner of macOS windows, input controls and system dialogs.
