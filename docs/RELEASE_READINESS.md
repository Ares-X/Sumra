# Release readiness

The [current work list](RELEASE_CHECKLIST.md) owns the remaining functional work,
current build/runtime evidence and signing/archive status. It replaces the
repeated intermediate-candidate narratives previously maintained here.

The existing reader functions and owners are recorded in [implementation status](IMPLEMENTATION_STATUS.md),
[UI inventory](SUMATRA_UI_PARITY.md), [engine inventory](SUMATRA_ENGINE_PARITY.md)
and [sampled corpus results](BOOK_CORPUS_ACCEPTANCE.md). The [Markdown decision](MARKDOWN_RENDERER_DECISION.md)
records the approved rendering strategy. These inventories are references, not
separate mandatory test matrices.

Build, source/archive correspondence and license notices use the existing
[scripts](../scripts) and [THIRD_PARTY.md](../THIRD_PARTY.md). Packaging does not
publish. The user selected the personal identity
`Ares-X Code Signing`, shared with Linnet and future personal projects. Its public
certificate SHA-256 is `e39f468d1dd2735ca8221e703999659c8f53efbab66408edfd310ecf02477104`.
For this identity, set `SUMRA_CODE_SIGN_IDENTITY=066AF413DC67F84BD8C2EA06B5CF0BAA14E5CAFD`,
`SUMRA_CODE_SIGN_KEYCHAIN="$HOME/Library/Keychains/Ares-X-Code-Signing.keychain-db"`
`SUMRA_CODE_SIGN_TIMESTAMP=none` and
`SUMRA_CODE_SIGN_ENTITLEMENTS=Assets/Community.entitlements` when building.
Unlock the dedicated Keychain using the maintainer's existing provisioning before
starting signing, and lock it again when signing is complete. The existing bundler signs
nested code and the outer app using the same options; the build script verifies
the resulting bundle. No certificate, private key or password is stored in the
repository. The community entitlement allows the reader to load its bundled
Sparkle and document engines: self-signed code has no Apple Team ID for Hardened
Runtime library validation. It is not used by default for Developer ID builds.
This certificate is self-signed; it does not provide Developer ID,
notarization or Gatekeeper acceptance. Candidate 856 completed signing with this
identity, strict/deep bundle verification, GUI startup and HTML/form/frame PDF
export. Its archive is local; GitHub publication is still pending.

Candidate 857 completed the native interface refresh: Home hides document reading
controls and the document sidebar; the reader uses one compact toolbar. Format
covers, a 120–200-point flexible search field and a 760-point maximum Home content
width are integrated. Home has a 560 × 500-point minimum content size; the reader
retains 560 × 400. Actual GUI checks covered the Home minimum, a maximized window,
light/dark appearance and contents search. Four screenshots use only the original
[demo document](demos/Reading-Notes.md). The optimized build, five affected reader
tests and 17 packaging tests passed. Normal opening uses Launch Services with
`LSMultipleInstancesProhibited`; the development launcher no longer requests a
new instance. Three obsolete test apps were stopped and retired; one current
preview remains. This UI work reuses unchanged document-engine evidence. Its
personal-signature and public archive refresh remain to be completed.

Historical runtime measurements and the before-edit narrative snapshot remain
in internal records retained locally, outside the public documentation.
