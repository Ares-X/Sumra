# Online updates

Sumra 0.2.1 and later use the existing pinned Sparkle framework. It owns scheduled
checks, download verification, installation and relaunch. Stable is the default;
the prerelease setting additionally permits appcast items in the `prerelease`
channel. Automatic checks run daily; the menu allows an immediate check. The
user approves installation. Version 0.2.0 needs one manual installation because
its bundle contains neither the feed URL nor the update public key.

`Assets/Updates.json` owns the HTTPS feed URL, public Ed25519 key and Keychain
account. Normal builds embed those settings. `SUMRA_UPDATE_FEED_URL` and
`SUMRA_UPDATE_PUBLIC_KEY` can override them for isolated local checks; setting
both to empty strings makes an unconfigured development bundle.

The macOS app and Sparkle helpers keep the shared **Ares-X Code Signing**
certificate. Sparkle's archive signature uses the personal **Ares-X** account
in the login Keychain, service `https://sparkle-project.org`. This is an Ed25519
update key, not another macOS signing certificate. Private material remains
in Keychain; only its public half is stored in this repository. Preserve this
key for future releases. See [Sparkle's setup](https://sparkle-project.org/documentation/).

## Publishing the next update

1. Increase `SUMRA_VERSION` and `SUMRA_BUILD_VERSION` and build/sign the app with
   the existing personal certificate. Sparkle compares the increasing build number.
2. Create the normal release ZIP and corresponding-source artifacts using
   `scripts/package-release.py`. If the ZIP has already been signed and tested,
   pass `--app-archive path/to/the.zip` to reuse its exact bytes on the same
   filesystem, without recompressing or signing it again.
3. Run `python3 scripts/generate-appcast.py path/to/Sumra-VERSION-macOS-arm64.zip`.
   For a preview, add `--channel prerelease`. This invokes the pinned upstream
   `generate_appcast`, signs the ZIP using Keychain, and preserves existing feed
   items. It generates no delta archives.
4. Review and commit `appcast.xml`; publish the GitHub Release and its signed ZIP
   before merging the feed update into `main`. The feed then references a
   downloadable release. Preview releases use the same feed and are excluded
   for users of the stable channel.
5. Verify the anonymous feed and enclosure URL, then use the previous configured
   build to check, download, install and relaunch the new build.

The appcast is release metadata rather than an input to the compiled app.
Updating it does not require another application build. Application signing is
still personal and nonnotarized; online updates do not change macOS trust policy.

## Verified 0.2.1 delivery

On macOS 27.0.1, an isolated 0.2.0/build 2 fixture with the feed and public key
configured discovered, downloaded, verified, installed and relaunched 0.2.1/build 3.
The installed bundle matched the signed release candidate, and strict/deep code
signature verification passed. The archive signature also passed an independent
CryptoKit check using the shipped public key. The user update flow did not access
the publishing private key or request a Keychain password. This fixture does not
make the original, unconfigured public 0.2.0 automatically updateable.
