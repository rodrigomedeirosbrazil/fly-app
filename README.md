# fly-app

Flutter app for Android and iOS that shows live telemetry from the
[fly-controller](https://github.com/rodrigomedeirosbrazil/fly-controller)
electric paramotor controller over Bluetooth LE.

Today it is a read-only flight instrument: state of charge, pack voltage,
current, motor and ESC temperatures, available power and throttle, at 1 Hz.
It reads the telemetry sentence the controller already broadcasts for XCTrack,
so it needs no firmware change.

Later phases add settings, log download and firmware update over BLE,
eventually replacing the controller's WiFi config portal. See
[docs/ROADMAP.md](docs/ROADMAP.md).

## Running it

```bash
flutter test      # 60 tests, no hardware needed
flutter analyze
```

On a connected iPhone (Xcode required):

```bash
flutter build ios --release
flutter install --release -d <device-id>   # `flutter devices` lists them
```

`flutter install` does not build — always build first. An emulator or simulator
will not do; neither has a Bluetooth radio.

Android needs the Android SDK, which is not set up on the dev machine yet.

## Installing on a phone

There is no App Store or Play Store build. iOS is signed with a free personal
Apple ID, which means **the app stops opening after 7 days** and has to be
reinstalled. The device also needs Developer Mode enabled and the certificate
trusted in Settings → General → VPN & Device Management.

## In a browser — and on an iPhone without a build

The same app runs on the web over Web Bluetooth:

**https://rodrigomedeirosbrazil.github.io/fly-app/**

- **iPhone / iPad:** Safari has no Web Bluetooth. Install
  [Bluefy](https://apps.apple.com/app/bluefy-web-ble-browser/id1492822055)
  (free) and open the address **inside Bluefy**. Tapping the link elsewhere
  opens Safari, which cannot reach the controller.
- **Android and desktop:** Chrome or Edge, no install.
- Firmware updates take the `.bin` from the
  [fly-controller releases](https://github.com/rodrigomedeirosbrazil/fly-controller/releases)
  through the file picker — the web build does not download from GitHub.

[CLAUDE.md](CLAUDE.md) (section Web) has what differs from the native build
and how the site is deployed.

## Working on it

[CLAUDE.md](CLAUDE.md) is the project guide: architecture, the rules the
parser and UI follow, the iOS gotchas, and the licensing constraint on
`flutter_blue_plus`.
