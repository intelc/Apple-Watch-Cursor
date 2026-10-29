# Security

Apple-Watch-Cursor is an experimental local input controller. Granting Accessibility lets it move and click the Mac cursor. Use Practice to evaluate behavior before enabling live input.

The Mac approves a Bluetooth central identifier once. Input is bound to that central, a fresh session, increasing sequence numbers and fresh motion. Reconnect does not enable live mouse input automatically. These checks do not provide cryptographic peer identity, explicitly require BLE link encryption, or constitute a security audit. Do not rely on the prototype in a hostile Bluetooth environment.

No runtime backend or telemetry is implemented. Calibration recordings and bounded diagnostics are local; review anything you share publicly.

For sensitive reports, use the repository's **Security → Report a vulnerability** option if available. If it is unavailable, open an issue requesting a private reporting channel without publishing exploit details or private data. Only the latest developer preview is maintained; there is no security support guarantee.
