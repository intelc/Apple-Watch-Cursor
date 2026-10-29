# Verification

## Instructions verified — October 29, 2026

Verification started from the public HTTPS repository in a new temporary directory, with interactive Git authentication and credential helpers disabled. The tested source commit was `edfc152318256e43b022f8fcfc5be25398cfefda` (the `v0.6.0` release). The instruction follow-up changes only documentation.

| Check | Result |
| --- | --- |
| Public clone and checked-in Xcode project | Passed; no XcodeGen or third-party dependency installation required |
| Xcode schemes | `AppleWatchCursorMac` and `AppleWatchCursorWatch` resolved with the local core package |
| `swift test` in the fresh clone | 70 tests, 0 failures |
| Documented unsigned Mac build | `BUILD SUCCEEDED`; fresh DerivedData, no signing/provisioning |
| Documented unsigned physical-target Watch build | `BUILD SUCCEEDED`; fresh DerivedData, no connected device required |
| Default Mac build with no development team | Passed on the verification host; local signing behavior is separate from Watch device provisioning |
| `bash scripts/package-preview.sh` from the clean clone | Passed; universal arm64 + x86_64 Mac developer ZIP, tracked-source ZIP and checksum file produced |
| Anonymous public release downloads | Both ZIPs and `SHA256SUMS.txt` downloaded without a GitHub token; both checksums passed |
| Downloaded source contents | All 52 tracked files matched the clean release checkout byte for byte |
| Downloaded Mac app | Extracted signature verification passed; both arm64 and x86_64 slices present |
| GitHub-hosted CI for the release commit | Passed tests and both unsigned native builds on a fresh hosted runner |

Local environment: Xcode 27.1, Swift 6.4. The unsigned command checks used separate new DerivedData directories instead of reusing prior build products. No installed copy, private sensor recordings or private package dependencies were used to validate compilation/tests.

The guide now includes full-Xcode/SDK preflight commands, signing configuration and unique identifiers before the first device Run, a build-only path with expected results, and the recording argument required by the optional replay tool.

**Scope:** this verifies public access, documented compilation, automated logic tests, release integrity and packaging. It does not prove that a new person can provision a Watch with a different Apple account, grant permissions, or obtain accurate taps on different hardware. That still requires their own signed installation and the [physical-device evaluation](HARDWARE-VALIDATION.md). Earlier Series 10 observations below remain the hardware evidence; they were not repeated during this instruction audit.

## 0.6.0 developer preview

The shared core has 70 passing tests. The original 0.6.0 native Mac and Watch development builds passed strict signature verification; the Watch app was installed and used on a physical Series 10. The publication rename changes the project/module/UI names while retaining bundle identifiers and runtime behavior. Publication build results are recorded in the GitHub prerelease notes.

Automated coverage includes full quaternion orientation and learned-axis mapping, elbow arcs, recentering, interrupted/stale motion, guided tap training, synthetic pulse/noise detection, malformed Bluetooth frames, session sequence/replay checks, retry/watchdog behavior, movement coalescing, independent preview feedback, delayed single clicks and consumed double-tap gestures.

Synthetic detector tests validate logic, not human gesture accuracy. A private local calibration recording also replayed six matching events for its six cues; that is training-set evidence, not an independent accuracy benchmark. Recordings and device diagnostics are excluded from the repository and public packages.

## Physical observations

- Tested with an Apple Watch Series 10, worn on the right wrist; last recorded device environment: watchOS 26.6.
- Six-cue personal calibration persisted and a subsequent live check counted all ten deliberate taps on Mac.
- One-time trust connected without a code. Stopping and restarting Mac Bluetooth reconnected automatically without another trust prompt.
- Preview red flash and received-tap counter were confirmed, including while live input was disabled.
- Double finger-tap mode entry/exit and single clicks were confirmed.
- Full 3D calibration completed all four animated sweeps in two runs, saved mappings, and was followed by user-confirmed working calibration and mouse control. Measured axis separation was approximately 74–88 degrees across those runs.
- Sustained use remains limited by Watch inactivity: silent movement freezes were restored by waking the display, sometimes without a Bluetooth disconnect.

No quantitative false-click, long-session, latency, battery, left-wrist, multi-user or broad device-compatibility claim is made. See [HARDWARE-VALIDATION.md](HARDWARE-VALIDATION.md) for the evaluation plan.
