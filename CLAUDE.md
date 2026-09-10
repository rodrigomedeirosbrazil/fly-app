# Fly App — Claude Code Guide

Flutter app (Android + iOS) that reads live telemetry from the
[fly-controller](https://github.com/rodrigomedeirosbrazil/fly-controller)
electric paramotor controller over BLE.

Two sibling repos: **fly-controller** (the ESP32-C3 firmware) and
**fly-throttle** (the wireless remote throttle). This app talks only to
fly-controller, and only listens.

## Build System

**Framework:** Flutter 3.47.3 (stable) · **Dart SDK:** ^3.13.3

```bash
flutter test                  # 60 tests, no hardware needed
flutter analyze               # must be clean
flutter build ios --release   # needs Xcode
flutter build apk --release   # needs the Android SDK (not installed yet)
```

Installing on a connected iPhone:

```bash
flutter build ios --release && flutter install --release -d <device-id>
```

**`flutter install` does not build.** It packages whatever is already in
`build/`, so on its own it will happily reinstall a stale binary and report
success. Always `flutter build` first, or use `flutter run`. Check
`stat -f "%Sm" build/ios/iphoneos/Runner.app/Runner` against your last edit if
the device shows no change.

`flutter devices` lists connected hardware. An emulator or simulator is useless
here — neither has a Bluetooth radio.

## Dependencies

| Package | Version | Why |
|---|---|---|
| `flutter_blue_plus` | 2.3.12 | BLE central. **See Licensing below.** |
| `permission_handler` | 13.0.2 | Android 12+ runtime BLUETOOTH_SCAN / CONNECT |
| `wakelock_plus` | 1.8.0 | Screen stays on in flight |
| `shared_preferences` | 2.5.5 | Remembers the pack/per-cell voltage mode |

Plugins resolve through **Swift Package Manager**, not CocoaPods — Flutter 3.47
migrated. There is no Podfile.

`pubspec.lock` is committed on purpose. Flutter's default gitignore drops it,
but that rule is for packages; for an application it means two builds of the
same tag can resolve different dependencies.

## The wire contract

The controller advertises as **`FlyController`** with a Nordic UART Service and
notifies one ASCII line per second:

| | |
|---|---|
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| TX characteristic (notify only) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |
| Sentence | `$XCTOD,<16 comma-separated fields>\r\n` |

**There is no write characteristic.** This app can listen and nothing else.
Every command, setting and firmware update is phase 2 or later — see
[docs/ROADMAP.md](docs/ROADMAP.md).

The canonical field table lives in the firmware repo at
`docs/XCTOD-PROTOCOL.md`. `lib/protocol/xctod_parser.dart` is a **second
implementation of that contract in another repository**, with no shared package
between them — the same situation as `RemoteLinkProtocol.h` between
fly-controller and fly-throttle.

> Fields are read **by position**. Inserting a field anywhere but the end
> shifts every later one and breaks this parser silently — it will decode, just
> into the wrong columns. A firmware change to the sentence is a change to this
> repo too.

## Project Structure

```
lib/
├── protocol/   xctod_frame.dart · xctod_parser.dart · line_assembler.dart
├── state/      link_health.dart · telemetry_repository.dart
├── ble/        fly_controller_link.dart
└── ui/         app.dart · connection_screen.dart · flight_screen.dart
                widgets/dial.dart
```

The layering is the point, and it is worth preserving:

- **`protocol/`** and **`state/link_health.dart`** import nothing from
  `package:flutter`. They are the Dart analogue of the firmware's host-testable
  headers (`ThrottleSignalLogic.h`, `PowerAlertLogic.h`): pure decision logic,
  fully tested in milliseconds with no device attached. Do not break this.
- **`ble/`** is the only file that touches a radio. Everything above it is
  testable precisely because that is true.
- **`state/telemetry_repository.dart`** is glue with no rules of its own.
- **`ui/`** reads state and never touches BLE.

## Key Patterns

### An empty field is not zero

The firmware emits an empty CSV field when **its own** validity check failed —
no sensor, stale CAN frame, unplugged NTC. It parses to `null`, and the UI
**hides** that element rather than printing `N/A` or `0`. A `0 °C` on the motor
dial reads as a cold motor, not a missing sensor. This is the single most
important rule in the codebase.

A *non-empty* field that fails to parse is a different thing: it rejects the
whole frame. Conflating the two would turn a corrupt line into a screenful of
plausible nulls.

### Stale data is worse than no data

`LinkHealth` withholds the frame entirely once it is older than 3 seconds
(three missed notifications at 1 Hz) — it is not returned with a flag the UI
might forget to honour. A frozen number the pilot reads as current is the
failure being designed against, the same reasoning as the firmware's
`ThrottleSignalLogic`.

Rejected lines are counted and do **not** refresh the clock: a stream of
garbage must age out exactly like silence.

### MTU

`requestMtu(247)` runs on **Android only**. Android's default ATT MTU is 23,
which caps a notification at 20 bytes and would truncate every ~90-byte
sentence; iOS negotiates 185 on its own and CoreBluetooth rejects the call.

Frames that fail the 16-field count are counted and the total is shown on the
connection screen. Non-zero there with no telemetry is the signature of an MTU
that never grew — which is why it is surfaced rather than silenced.

### Nothing enters or leaves the card stack

Status, battery, instruments, throttle, drawer bar — fixed order, fixed
presence. A fault shows as a chip in space the status row already reserves; a
limiter shows as a `DISPONÍVEL xx %` chip. No banner, ever. An alert must not
shift a number the pilot is in the middle of reading. Missing data collapses
within its own card (no current → the cell drops and the voltage centres).

### The drawer is in the tree, not a route

`showModalBottomSheet` pushes a route that builds once from the frame captured
at push time and never sees another, so its readings silently freeze at 1 Hz.
The secondary-data overlay is a `Stack` child of `FlightScreen`, rebuilt by the
same `setState`. There is a regression test for this.

### Sizes are proportional, never point constants

Dials and readouts size against their box, the way the web panel uses `clamp()`.
A fixed 38 pt number looks right on the phone it was written on and wraps into
two lines on a narrower one — that is how the panel first overflowed. Every
string that must not wrap carries `maxLines: 1`.

`test/ui/flight_screen_test.dart` pumps the screen at four device sizes; a
widget test fails on `RenderFlex overflowed`, so the pump *is* the assertion.

### Colours are spelled out

`ColorScheme.fromSeed` tints every surface toward the seed hue, which turned
the background green. The palette in `ui/app.dart` is explicit and neutral, so
the only colour on screen is the data: green for the gauge, blue for throttle,
red for armed and faults.

## Testing

```bash
flutter test                                  # everything
flutter test test/protocol/                   # the parser — where correctness lives
```

The parser suite is the real safety net: a corpus of real sentences plus
truncated lines, wrong field counts, an empty field in every position, every
disarm code, both motor-temp sources. It needs no hardware and runs instantly.

What tests cannot cover, and must be checked on a device: MTU negotiation on
Android, and coexistence with XCTrack connected at the same time. Both are open
— see [docs/ROADMAP.md](docs/ROADMAP.md).

## Conventions

- **Language:** code, comments, documentation and commit messages in
  **English**. User-facing strings in the UI are in **Brazilian Portuguese** —
  the same split as fly-controller.
- Commit messages carry the *why*, not a restatement of the diff.
- `docs/superpowers/` (specs and plans) is gitignored working material. Durable
  reasoning belongs in this file, in `docs/ROADMAP.md`, or in a commit message.

## iOS

Signed with a **free personal Apple ID** (team `KP44BA9VNZ`, bundle
`com.rodrigomedeiros.flyApp`), so:

- **Builds expire after 7 days** and must be reinstalled.
- The device needs **Developer Mode** (Settings → Privacy & Security). The menu
  only appears after Xcode has tried to use the device once; before that,
  `devicectl list devices` reports `connected (no DDI)`.
- First launch needs the certificate trusted in Settings → General → VPN &
  Device Management.
- `NSBluetoothAlwaysUsageDescription` in `ios/Runner/Info.plist` is mandatory —
  without it iOS refuses to scan, silently.

Wireless installs work, but pairing requires one USB connection first
(Xcode → Window → Devices and Simulators → Connect via network).

## Licensing

`flutter_blue_plus` 2.3.12 requires a `license` argument on `connect()`. It is
set to `License.nonprofit`, which covers personal, nonprofit and educational
use. **Commercial distribution requires `License.commercial`, a paid licence.**
If this app is ever sold, bundled with a controller sold for profit, or shipped
by a company, that has to be dealt with first.

## What is deliberately absent

Not oversights — this data does not exist on the BLE stream:

- **Flight clock** (`sessionSec`)
- **Which limiter is acting** (`powerAlert.causes[]`)
- **The red reduction band** on the thermal dials — the thresholds are
  configurable in the controller's NVS, so drawing the factory 80/100 °C would
  show a number that may not be this pilot's
- **Buzzer mirroring**

All four need phase 2.
