# Development and packaging

## Project

Open `AppleWatchCursor.xcodeproj`. The schemes are `AppleWatchCursorMac` and `AppleWatchCursorWatch`; the shared package/module is `AppleWatchCursorCore`. Deployment targets are macOS 14 and watchOS 10. The verified local compiler environment is Xcode 27.1 with Swift 6.4 in Swift 5 language mode.

The checked-in Xcode project works without XcodeGen. If you edit `project.yml`, regenerate with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
```

`dev.yiheng.wristpilot.mac` and `dev.yiheng.wristpilot.watch` are legacy bundle identifiers retained for upgrades. They are identifiers, not signing credentials. New builders should set their own unique identifiers and development team in Xcode. If using XcodeGen, update both target `PRODUCT_BUNDLE_IDENTIFIER` values and `bundleIdPrefix` in `project.yml` first; regeneration otherwise replaces Xcode-only edits. Changing identifiers creates separate app storage and may require new permissions, trust and calibration.

## Test and compile without signing

```sh
swift test
xcodebuild -project AppleWatchCursor.xcodeproj -scheme AppleWatchCursorMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/apple-watch-cursor-mac \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project AppleWatchCursor.xcodeproj -scheme AppleWatchCursorWatch \
  -destination 'generic/platform=watchOS' -derivedDataPath /tmp/apple-watch-cursor-watch \
  CODE_SIGNING_ALLOWED=NO build
```

Expected results are 70 passing tests and `BUILD SUCCEEDED` for each native app. Unsigned builds check compilation; they do not install or launch a Watch app or establish sensor accuracy. No Apple account, signing identity, physical device, XcodeGen or third-party dependency installation is needed for this build-only path. Full Xcode with the watchOS SDK is required; standalone Command Line Tools are insufficient.

The optional replay tool requires a local calibration recording:

```sh
swift run TapReplay /path/to/your/recording.json
```

An optional third argument supplies a numeric detector threshold. A recording is not included in the public repository; the core tests use synthetic data and need no private recording. Do not run the replay tool without a recording argument, and do not commit recordings or device diagnostics.

## Local signed builds

After configuring an account, team and unique identifiers in Xcode:

```sh
bash scripts/build-signed.sh YOUR_APPLE_TEAM_ID
```

This helper uses Xcode automatic development signing and provisioning. It writes temporary build products outside the checkout, verifies signatures, and saves private device-development ZIPs under ignored `build/artifacts/`. It does not install or launch the apps. Watch development profiles are device-specific: **do not upload these signed archives to public releases**.

Use Xcode's physical Watch destination to install. If the destination is missing, keep the Watch unlocked, check its development pairing, and connect the paired iPhone when needed. See [Apple's device-run guide](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html) and [watch-only app guide](https://help.apple.com/xcode/mac/current/en.lproj/devaba4602fd.html).

## Public developer package

From a clean committed **Git clone** (the release source ZIP has no Git history):

```sh
bash scripts/package-preview.sh
```

The script requires Git, Xcode command-line tools and an Apple Silicon or Intel Mac. It builds a **universal arm64 + x86_64 Release Mac app**, adds a local ad hoc signature, verifies it, and packages it with setup/distribution notes and the license. It also archives tracked source and writes SHA-256 checksums to ignored `build/release/`. Temporary app bundles stay outside the repository so synced-folder metadata cannot interfere with signing.

The public package deliberately excludes development-signed Watch binaries, provisioning profiles, signing credentials, sensor recordings and diagnostics. Its Mac signature is not a Developer ID identity, and it is **not notarized**. Source builds remain the recommended setup path. A downloadable Mac binary alone cannot install the Watch app.

A future end-user release needs an actual Watch distribution path and Mac distribution signing/notarization. Follow [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution); the preview script is not a replacement for that process.

## Before releasing

1. Run `swift test` and unsigned native builds for both schemes.
2. Follow the [hardware test plan](HARDWARE-VALIDATION.md); keep unmeasured results labeled as unmeasured.
3. Update version/build in `project.yml`, regenerate the project, and update `CHANGELOG.md`.
4. Commit the release tree, run the packaging script, and inspect archive contents and checksums.
5. Tag the exact commit and publish a prerelease with the developer-distribution limitation stated prominently.
