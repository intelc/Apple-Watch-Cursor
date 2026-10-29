# Hardware evaluation plan

The required interaction is right-wrist pointing, index-finger-to-thumb single taps for left clicks, double taps for mouse-mode entry/exit, primary-display confinement and a Watch-screen Recenter button.

Functional observations are in [BUILD-VALIDATION.md](BUILD-VALIDATION.md). The following are evaluation targets, not completed acceptance results.

1. Record Watch model, OS, wrist/crown configuration, strap fit, app version and delivered accelerometer rate. Do not publish device identifiers.
2. Complete six-cue finger calibration. In Practice, make 50 separate taps while holding the wrist still. Record detections, misses and duplicates. Initial target: at least 45/50 detected with no duplicates.
3. Repeat 50 taps after moving to several targets. Record whether the preview stays at the intended target during a tap. Initial target: at least 45/50 detected and fewer than 5% displaced by more than a small button's width.
4. Spend five minutes moving, typing, resting the hand and touching the Watch without deliberate finger taps. Record false detections. Initial target: zero false clicks in Practice. Refine with positive and negative recordings if this fails.
5. Complete top→bottom, bottom→top, left→right and right→left pointing sweeps, including natural elbow-centered horizontal arcs. Confirm check marks, automatic advancement, saved mapping, correct signs, diagonal motion and comfortable edge reach. Check cancellation, invalid calibration and connection loss preserve the prior mapping. Test restart persistence and ten recenters from different poses; screen presses must not click.
6. With harmless targets, confirm double taps toggle mouse mode without clicking; single taps produce one down/up pair at the original target after the decision delay. Check partial doubles, third taps, Pause, Accessibility denial and primary-display confinement. Confirm click-down never remains held.
7. Test Bluetooth off, lost range, Mac sleep, Watch dimming/backgrounding, trust revocation and reconnect. Stale input must stop and reconnect must leave native input off. Waking the display may be needed to restore sensor delivery in this preview.
8. Measure latency and battery in a short session, and repeat across people and Watch models before claiming general performance.

The dim-display runtime limitation and unaudited Bluetooth trust remain open product work. Successful compilation or a single live tap run does not establish these acceptance targets.
