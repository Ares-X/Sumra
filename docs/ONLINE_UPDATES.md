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
update key, not another macOS signing certificate. Local signing uses Keychain;
the release Action uses the same key from an encrypted repository Secret.
Only its public half is stored in this repository. Preserve this key for future
releases. See [Sparkle's setup](https://sparkle-project.org/documentation/).

For local maintainer signing, `SUMRA_CODE_SIGN_PASSWORD_FILE` can point to an
existing protected Keychain password file. `SUMRA_CODE_SIGN_UNLOCK_KEYCHAIN`
selects the Keychain containing the private key; it defaults to
`SUMRA_CODE_SIGN_KEYCHAIN`. The bundler unlocks it only for signing and restores
its locked state afterward. Certificate selection still uses
`SUMRA_CODE_SIGN_IDENTITY`; neither passwords nor private keys enter the app or
source package. A certificate and its matching key may reside in different
Keychains, in which case omit `SUMRA_CODE_SIGN_KEYCHAIN` to use the existing
user search list.

## Publishing the next update

Follow [the Action release procedure](RELEASE_ACTIONS.md): build a draft from the
exact source commit, download and validate that app, then publish the accepted
files and update the feed. Sparkle compares the increasing default build number
in `scripts/bundle.swift`.

The Action invokes the pinned upstream `generate_appcast` through
`scripts/generate-appcast.swift`, passing `SUMRA_SPARKLE_PRIVATE_KEY_FILE` from
its temporary signing directory. Local maintainer invocation uses the existing
Keychain account. The generator preserves existing feed items and generates no
delta archives. `--channel prerelease` remains available for local preview feed
generation; stable users exclude that channel.

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
