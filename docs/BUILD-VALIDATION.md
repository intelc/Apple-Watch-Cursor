# Verification

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
