# Release through GitHub Actions

Sumra follows Linnet's candidate-and-publication flow. Local checks establish
behavior, then the release Action builds and signs one candidate from an exact
commit. The maintainer downloads those draft Release files and validates that
app with the original books. A second Action invocation publishes the same
accepted files and updates the feed after the download is public.

The [release workflow](../.github/workflows/release.yml) uses the existing
`build-app.sh`, `package-release.swift` and `generate-appcast.swift` owners.
It adds no application dependency. The macOS runner builds arm64 with the
existing macOS 13 deployment target. Runtime acceptance still records the
macOS version actually exercised.

The first clean Action build exposed changing Gitiles archive bytes for the
existing skcms revision. Its source now uses the same pinned-Git approach as
MuPDF, through Google's official mirror. The revision and source file contents
remain unchanged. Corresponding-source exports retain its revision marker.

Clean builds also use `Native/mupdf-submodules.txt` for both fetching and source
packaging. It contains the modules actually compiled into Sumra's MuPDF library;
unused OCR, office-export, barcode and upstream viewer modules are omitted.

## Signing setup

Configure these encrypted Secrets in **Ares-X/Sumra** once:

- `SUMRA_CODE_SIGNING_P12_BASE64`: the existing Sumra certificate and private
  key, exported as a password-protected P12 and encoded as base64.
- `SUMRA_CODE_SIGNING_P12_PASSWORD`: that export's password.
- `SUMRA_SPARKLE_PRIVATE_KEY`: the existing Ares-X Sparkle key exported by
  the pinned `generate_keys --account Ares-X -x FILE` tool.

The app identity remains SHA-1 `066AF413DC67F84BD8C2EA06B5CF0BAA14E5CAFD`.
The update public key remains in `Assets/Updates.json`. Neither private key
enters the repository, app or corresponding-source archive. The Action imports
the app identity into a temporary Keychain on the disposable runner's search
list, verifies a small signing operation before compilation, and removes all signing material
when the job ends. Distribution remains self-signed and nonnotarized.

## Candidate and publication

1. Set the next default version/build in `scripts/bundle.swift`. Complete the
   affected local checks and commit the source, workflow and release notes.
2. Dispatch **Sumra release** with `mode=candidate`, the full `source_revision`
   and `version`. It stages `sumra-candidate/vVERSION-SHA` as a draft Release.
   The build freezes prepared source inputs and records the verified signed
   bundle before packaging the app, source, provenance, checksums and appcast.
3. Download the draft's files. Verify `SHA256SUMS`, the existing certificate,
   version, architecture and source correspondence. Open this exact app and
   exercise the changed original-book workflows. Retain the actual observations.
4. Dispatch the same workflow with `mode=publish`, the same revision/version
   and `accepted_manifest_sha256` equal to the accepted `SHA256SUMS` file's
   SHA-256. The Action verifies those draft bytes, publishes them under
   `vVERSION`, then commits their appcast to `main`. It does not rebuild,
   sign, recompress or upload replacement application files.
5. Verify anonymous downloads and the update signature, then use the previous
   configured public app to check, install and relaunch the new version.

The appcast commit is delivery metadata and does not change the compiled app's
source revision. Draft candidates are private to repository maintainers; only
the publication invocation exposes a new public release.

If the Release becomes public but the subsequent feed commit fails, inspect the
public Release and its accepted manifest before repairing the feed. Execute only
the workflow's feed-update step against the downloaded, verified appcast; do not
rerun publication or replace the public assets. The job reports a failed feed
commit rather than claiming successful update delivery.
