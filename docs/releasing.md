# Releasing AI Usage

AI Usage ships as a universal DMG and uses Sparkle 2 for signed over-the-air
updates.

## Prerequisites

- Xcode 27 or newer
- GitHub CLI authenticated for `burakgon/ai-usage-menubar`
- The `ai-usage-menubar` Sparkle EdDSA key in the login Keychain
- A `Developer ID Application` certificate for a notarized public build

The Sparkle private key is never stored in this repository. The public key is
embedded in `AIUsage/Info.plist`. Back up the private key in a secure secret
manager before moving release duties to another Mac.

## Prepare a version

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode
   project.
2. Add `docs/releases/<version>.md`.
3. Commit and test the source changes.

## Build the DMG and appcast

```bash
./scripts/package_release.sh 0.1.0
```

The script:

- builds a universal arm64/x86_64 Release app;
- verifies the app bundle and embedded update configuration;
- creates `dist/v<version>/AI-Usage.dmg`;
- signs the update with the private EdDSA key in Keychain;
- updates the signed `appcast.xml`.

If a Developer ID certificate and a `notarytool` Keychain profile are
available, notarize in the same pass:

```bash
NOTARYTOOL_PROFILE=ai-usage-notary ./scripts/package_release.sh 0.1.0
```

## Publish

Review and commit the generated `appcast.xml`, then create an annotated
`v<version>` tag at that commit. Push the commit and tag before uploading the
DMG so the in-app feed is live:

```bash
gh release create v0.1.0 \
  dist/v0.1.0/AI-Usage.dmg \
  dist/v0.1.0/AI-Usage.dmg.sha256 \
  --title "AI Usage 0.1.0" \
  --notes-file docs/releases/0.1.0.md
```

Finally, verify that the raw appcast and the DMG enclosure URL both return
HTTP 200.
