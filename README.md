# iambusy

A minimal macOS menu bar app for the [Kuando Busylight](https://busylight.com)
(Alpha and Omega). Turn the light on and off, pick the intensity, done.

No server, no Python, no dependencies — a single native SwiftUI app that talks
to the device directly over HID via IOKit.

## Features

- Lives in the menu bar (`MenuBarExtra`), no Dock icon
- Turn the light on (red) and off
- Intensity levels: 10%, 25% (default), 50%, 100%
- Hot-plug aware: reconnecting the device restores the current state
- Handles the Kuando keepalive protocol automatically (the device turns
  itself off unless refreshed every few seconds)

## Requirements

- macOS 13 Ventura or later
- A Kuando Busylight Alpha or Omega
- Xcode Command Line Tools (Swift 5.9+) — only to build from source

## Run from source

```bash
swift run
```

A circle icon appears in the menu bar. The icon fills in while the light is on.

## Build a distributable app bundle

```bash
Scripts/make-app.sh [version]   # version defaults to 0.1.0
```

Produces `dist/IAmBusy.app` (universal arm64 + x86_64) and
`dist/IAmBusy-<version>.zip` ready to share.

The bundle is **ad-hoc signed only** (no Developer ID, no notarization), so
macOS Gatekeeper will block it on first launch on other machines: right-click
the app → **Open** → **Open** (one time only), or remove the quarantine flag:

```bash
xattr -d com.apple.quarantine IAmBusy.app
```

## Verify the protocol packing

```bash
swift run Busy --dump
```

Prints the raw 64-byte HID packets (on-red, off, keepalive). These are
byte-identical to the output of
[busylight-core](https://github.com/JnyJny/busylight_core)'s Kuando
implementation, which this app's protocol layer is ported from.

## Supported devices

| Device          | Vendor:Product IDs                          |
|-----------------|---------------------------------------------|
| Busylight Alpha | `04d8:f848`, `27bb:3bca`, `27bb:3bcb`, `27bb:3bce` |
| Busylight Omega | `27bb:3bcd`, `27bb:3bcf`                    |

## How it works

The Kuando protocol is a 64-byte HID output report: seven 64-bit "step"
instructions plus a footer with a byte-sum checksum, packed big-endian. This
app only uses step 0, with two opcodes:

- **Jump** — sets the LED color. Channels use the device's internal 0–100
  scale; intensity control is plain RGB scaling (the device has no separate
  brightness register).
- **KeepAlive** — the device quiesces unless it hears one before its timeout.
  The app refreshes every 10 s against a 15 s device-side timeout while the
  light is on. This also means the light always turns off within ~15 s of the
  app quitting — by hardware design.

## Project layout

```
Package.swift              # SPM manifest (executable target "Busy")
Scripts/make-app.sh        # Build IAmBusy.app + zip for distribution
Sources/Busy/
├── BusyApp.swift          # SwiftUI MenuBarExtra UI
├── KuandoController.swift # IOKit HID device management + keepalive timer
└── Kuando.swift           # Protocol: packet building, device IDs
```

## Roadmap

- [x] `.app` bundle packaging script (unsigned)
- [ ] Full color picker (the protocol layer already takes arbitrary RGB)
- [ ] Launch at login (`SMAppService`)
- [ ] Signed + notarized releases (Developer ID)
- [ ] App icon

## Credits

Protocol reverse-engineering credit goes to
[JnyJny/busylight](https://github.com/JnyJny/busylight) and
[busylight-core](https://github.com/JnyJny/busylight_core) (Apache-2.0), whose
Kuando implementation this port was validated against, byte for byte.
