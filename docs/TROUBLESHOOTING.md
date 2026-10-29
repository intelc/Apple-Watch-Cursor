# Troubleshooting

## The pointer freezes when the Watch dims

This is an unresolved runtime limitation. Wake the Watch display and move again. Keep the app frontmost during use and calibration. If available on your watchOS version, a longer Wake Duration and per-app **Return to Clock → After 1 hour** can reduce interruptions, but cannot guarantee sensor execution while dimmed/backgrounded. See [Apple's display settings guide](https://support.apple.com/guide/watch/apd748b87e2a/watchos).

The app does not start an unrelated workout, audio or mindfulness session to obtain background runtime. Continuous wrist-down control is not a supported claim for this preview.

## The Watch will not connect

Allow Bluetooth on both devices and open both apps. Mac Bluetooth advertising starts automatically; check **Start Bluetooth** if stopped. On Watch use **Connection / Connect to Mac → Find Mac** if needed. Click **Trust this Watch** on Mac once. Do not look for a pairing code.

Automatic reconnect resumes when the preferred Mac returns. **Disconnect** on Watch intentionally stops retries until Find Mac is selected again. **Forget Watch** on Mac revokes trust and requires approval again. A reconnect leaves live mouse control off.

For installation failures, check the physical Watch destination, Xcode device support, development team, identifiers, Developer Mode and device pairing. Keep the Watch awake/unlocked and the paired iPhone nearby and USB-connected when required by the development connection. Wi-Fi can help Xcode device discovery; the app's runtime transport is Bluetooth LE.

## Horizontal calibration is rejected

Use the same version on both devices. Watch the animation, move to its starting end during the countdown, and hold still until the green **GO — MOVE NOW** banner. Make one comfortable sweep and hold at the finish. Horizontal movement can follow an arc around a relatively fixed elbow. Avoid making an out-and-back gesture in a single capture.

The reverse sweep starts at the endpoint from the previous pass. Horizontal and vertical rotation must still be distinguishable; tiny or nearly parallel movements cannot define a stable mapping. Keep the display awake so missing sensor callbacks do not interrupt the sweep. A rejected attempt does not erase the previous saved mapping.

## The Watch detects taps but Mac does not click

First enable **Practice in preview** and check whether the dot flashes red and the received-tap counter increases. That feedback is independent of Accessibility and live input authorization.

If taps arrive, turn Practice off, grant Accessibility and double finger tap to enter mouse mode. Wait for centering and fresh wrist data. A single click has about a half-second delay because a second tap may change the gesture into a mode toggle. Double taps intentionally produce no clicks.

If taps do not arrive, check connection state and Watch display wakefulness. If taps are not detected on Watch either, refit the strap and redo the six-cue calibration. Raw acceleration sampling must remain fast enough; the app reports sensor-rate problems.

## Directions or sensitivity feel wrong

Recalibrate all four pointing sweeps from your own perspective. Full 3D calibration learns signs and range, then clears manual flips and sets Y sensitivity to neutral. Use **Flip X**, **Flip Y**, or the **Y sensitivity** slider for subsequent adjustment. **Recenter** resets neutral, not the axis mapping; hold still while it finds center.

Only the primary display is controlled. Moving the hardware mouse to another display does not change that target.

## Pause, reset and remove

Use Pause on Mac, Watch or the Mac menu bar. Escape pauses while the Mac app is focused. Watch Pause stops sensors; **Arm mouse gestures** resumes them. Mouse control starts off after a restart/reconnect.

To reset connection trust, use **Forget Watch** on Mac, then reconnect and approve. To replace calibrations, rerun them; failed attempts retain the previous working profile.

To uninstall, quit the Mac app, remove it from Applications (or its local build folder), delete the Watch app, and remove its Accessibility entry in System Settings. Delete `~/Library/Application Support/Apple-Watch-Cursor` to remove Mac journals. Legacy prototype journals may remain in `~/Library/Application Support/WristPilot`.

Calibration and trusted-device settings are stored in the app's local preferences under its bundle identifier. For the shipped legacy Mac identifier, an optional full preference reset is:

```sh
# Quit the Mac app first. This clears calibration, trust, and settings.
defaults delete dev.yiheng.wristpilot.mac
```

Use your own identifier if you changed it. Removing the Watch app removes its app data, including the locally stored motion recordings.

## Reporting a problem

[Open a GitHub issue](https://github.com/intelc/Apple-Watch-Cursor/issues) with app version, device/OS versions, exact step and observed message. Include whether waking the display resumes motion. Do not post device identifiers, provisioning profiles, signing files or raw personal recordings. For security-sensitive details follow [SECURITY.md](../SECURITY.md).
