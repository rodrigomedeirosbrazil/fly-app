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
flutter test                  # 119 tests, no hardware needed
flutter analyze               # must be clean
flutter build ios --release   # needs Xcode
flutter build apk --release   # signed APK, ~45 MB (all three ABIs)
flutter build apk --debug     # validates the Android config with no device
```

`flutter build apk --debug` is worth knowing: it is the cheapest way to
exercise the manifest merger and the Kotlin compile, and it needs no phone.
`flutter analyze` and `flutter test` touch none of that.

Handing the APK to another pilot:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Unlike the iOS build, **an Android APK does not expire.** Whoever receives it
keeps a working copy indefinitely.

Installing on a connected iPhone:

```bash
flutter build ios --release && flutter install --release -d <device-id>
```

**`flutter install` does not build.** It packages whatever is already in
`build/`, so on its own it will happily reinstall a stale binary and report
success. Always `flutter build` first, or use `flutter run`. Check
`stat -f "%Sm" build/ios/iphoneos/Runner.app/Runner` against your last edit if
the device shows no change.

**`flutter install` can hang indefinitely on a wireless device**, and so can
`flutter devices` — both were observed sitting past a 10-minute timeout with
the phone unlocked and reachable. `devicectl` talks to it directly and does
not:

```bash
xcrun devicectl list devices
xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <udid> br.com.medeirostec.aerovolt
```

Still build with `flutter build ios --release` first — `devicectl` installs
whatever is in `build/`, with the same staleness trap as `flutter install`.

`flutter devices` lists connected hardware. An emulator or simulator is useless
here — neither has a Bluetooth radio.

## Dependencies

| Package | Version | Why |
|---|---|---|
| `flutter_blue_plus` | 2.3.12 | BLE central. **See Licensing below.** |
| `permission_handler` | 13.0.2 | Android 12+ runtime BLUETOOTH_SCAN / CONNECT |
| `wakelock_plus` | 1.8.0 | Screen stays on in flight |
| `shared_preferences` | 2.5.5 | Remembers the pack/per-cell voltage mode |
| `flutter_svg` | 2.3.0 | Renders the tintable Aerovolt logo |
| `flutter_launcher_icons` | 0.14.4 | **Dev only.** Generates the icon sets |

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

## The binary wire contract

The controller also serves a **Fly Control** GATT service carrying a 56-byte
binary telemetry struct at 1 Hz. It is not advertised — the 31-byte
advertising payload cannot hold a second 128-bit UUID — so the scan filter
stays on the NUS UUID and the service is found only after connecting.

| | |
|---|---|
| Service | `D4CF0001-9B9D-4BFD-8F7F-40C6989D3EA9` |
| `INFO` (read) | `D4CF0002-…` — 28 bytes, static for the session |
| `TELEMETRY` (notify) | `D4CF0003-…` — 56 bytes |
| `CMD` (write) | `D4CF0004-…` — `[op][seq][len][payload]` |
| `RSP` (notify) | `D4CF0005-…` — `[op][seq][status][len][payload]` |

`lib/protocol/control_telemetry_codec.dart` is the **second** hand-duplicated
fly-controller header in this repo, after `xctod_parser.dart`. The definition
of record is `src/BleControl/ControlProtocol.h`, described by
`docs/BLE-CONTROL-PROTOCOL.md`. Fields are read **by offset**, so the hazard is
identical to the CSV one: a field that moves in the firmware decodes silently
into the wrong column here. `test/ControlProtocolTest.cpp` there and
`test/protocol/control_telemetry_codec_test.dart` here pin the same numbers,
and they are the only thing that catches it.

### Service presence is the capability handshake

Firmware without the service simply does not have it, so a client that fails
to find it falls back to `$XCTOD`. **Do not delete that fallback.**

The source is chosen at discovery and **fixed once the first frame renders**.
Three things fall back, and all three can only happen before anything reaches
the screen: the service is absent, `INFO` will not read, or the first frame
carries an unknown struct `ver`. After that the source is locked — a flip
mid-flight would silently change which readings exist, and the flight clock
would vanish under a pilot reading it. `lib/state/telemetry_source_policy.dart`
is pure and table-tested for the same reason `ble_permission_policy.dart` is.

### The gate is the frame's `ver`, not `INFO.protocolVersion`

`ControlTelemetryCodec.kStructVersion` is **1**. The struct carries its own version at
offset 0, bumped only when a telemetry field changes position or meaning.
`INFO.protocolVersion` is broader — it also moves for config opcodes this app
never sends — so gating the panel on it would cost the flight clock for a
change that does not affect the panel. `protocolVersion` is recorded as a
diagnostic and nothing else.

Note the protocol document claims a higher `protocolVersion` still works
because of the append rule. That is not true in the case the bump is defined
for: if a field *moved*, appending saves nothing. See `ROADMAP.md`.

### A short packet is corruption, not an old struct

`ControlTelemetryCodec.kMinTelemetryLength` is **56**. Longer packets decode their first 56 bytes,
so future firmware works. Shorter ones are rejected whole and counted.

At protocol version 1 no older struct exists, so a short packet can only be
corruption or an ATT-truncated notification — which is what the rejected-frame
counter on the connection screen exists to diagnose. Decoding as far as the
bytes go would turn a 20-byte fragment into a panel of plausible readings with
the counter at zero. Same rule as the CSV parser: a malformed frame is
rejected whole, because conflating it with a missing reading produces a
screenful of convincing nulls.

**`rejectedFrames` now counts binary frames too.** Its meaning on the
connection screen is unchanged.

### Absence has three sources and one answer

`validity` bits cover availability (does this build produce the reading at
all): current, RPM, power, BMS, per-cell. `signalStates` packs sensor *health*
two bits at a time for motor temp, ESC temp and battery voltage — `Absent`,
`Stale`, `Invalid`, `Valid` — and **only `Valid` means the number can be
trusted, because zero is a legitimate reading**. `socCc` has neither and is
always present; `socVolt` has neither but follows the battery-voltage state,
because a percentage derived from a distrusted voltage is not a reading.

All three collapse to `null` in `TelemetryFrame`, so every widget keeps the
hide-don't-print-zero rule for free. The states themselves are carried
alongside, so the decode stays lossless.

### The request channel answers nothing when it fails

`CMD` and `RSP` carry requests and replies, matched by a one-byte sequence.
`lib/state/control_session.dart` owns that matching and is pure — it takes a
transport, so timeouts and sequence races test in milliseconds.

**A timeout is the only failure detector that exists.** The firmware answers
neither a malformed frame, because it cannot know which sequence to reply to,
nor a request its queue dropped — `ControlRequestQueue` is four deep, discards
the *newest* on overflow, and returns before any dispatch. The session waits
2 s, which is generous against a firmware loop that already ticks at 1 Hz and
well clear of its 10 s task watchdog.

**Sequences start at 1 and never reach 0.** That is what makes demultiplexing
free: `seq` 0 is reserved for unsolicited events, no pending request can carry
it, so an event falls through to `ControlSession.events` with no special case.
They also count upward without coming round again early — a request that timed
out may still have a reply in flight, and a reused number would let it complete
something else.

**The session never retries**, because it cannot tell a lost request from a
slow one. `PIN_CHANGE`, `SESSION_RESET` and `BUZZER_PREVIEW` are not safe to
repeat. Callers that know their request is a read retry themselves; the
thermal fetch does, three times.

A request may not exceed **32 bytes** of payload (`kMaxCommandPayload`). The
firmware copies it into a fixed queue slot and drops the whole request when it
does not fit, with no reply — so `encodeCommand` throws instead of sending.

Two rules with no UI behind them yet, recorded because subsystem 3 inherits
them: **`errState` must never prompt for a PIN** (`gateRequest()` reports armed
before auth precisely so a client does not ask for a password to do something
refused either way), and **`errBadOp` means "this firmware cannot do that"**,
not an error to show.

### The thermal band is the pilot's numbers, or nothing

`CFG_GET` of the `Thermal` group (17 bytes, id 1) is fetched **once per
connection**, triggered by the first decoded binary frame rather than by
connecting — at that point the source is settled and the service has produced
something.

**Nothing is cached.** The app cannot distinguish one controller from another
and the pilot can change these from the web portal, so a remembered threshold
would draw the band at a temperature that is not this aircraft's. A band that
is wrong is worse than no band, because it looks like information.

**A band is drawn only when `0 < start < end`.** An unconfigured NVS returns
zeros, and a band from zero to zero — or to the end of the scale — would paint
the whole dial red. Motor and ESC are judged separately.

**The band has two zones, because the derating does.** `Power::calcMotorTempLimit`
returns 100 below the reduction start, ramps linearly to 0 at the maximum, and
then `constrain(..., 0, 100)` holds it at **zero for every temperature above
that**. So the arc past the maximum is not a return to normal — it is the one
region where the motor is certainly not pushing. The ramp is drawn
translucent, the cut solid, and the cut runs to the end of the scale.

Drawing only the ramp was the first attempt and it was wrong in the most
misleading direction: it left the hottest part of the dial looking untouched.

The dial's scale stays **fixed at 140 °C**; only the band is configured. The
needle angle has to mean the same temperature on every aircraft and across a
configuration change, or the pilot's sense of where it sits when things are
fine stops transferring.

### Writing needs a PIN, and the PIN is never stored

`AUTH` (`0x01`) carries the PIN as raw characters. `BleControl::handleAuth`
requires an **exact length match** before comparing, and **fails closed**: a
wrong PIN clears whatever authentication the connection had already earned.

The app asks for it on the **first save of a connection**, never on opening the
settings screen — reads are open, so the screen shows current values without
prompting, and the flight panel prompts for nothing ever. Nothing is persisted:
no plaintext PIN on the device, none in a phone backup. The firmware clears
`authenticated_` in `onCentralDisconnected()`, so per-connection is the shape
it already expects.

**`ErrState` must never produce a PIN prompt.** `gateRequest()` reports armed
*before* auth precisely so a client does not ask for a password to do something
that would be refused either way.

`AUTH` and `CFG_SET` are **idempotent** — the same correct PIN, or the same
payload, lands on the same state — so `ConfigEditor` retries them on a timeout.
`PIN_CHANGE` is not, which is why the session itself never retries and each
caller decides.

### The app validates more than the firmware, on purpose

`lib/protocol/settings_validation.dart` is the **fourth** hand-copied
fly-controller contract here. Its mirrored half comes from
`src/Settings/SettingsValidation.h`; its second half does not exist there.

The firmware says why it has no ordering check: *"the portal has never had one,
and adding it here would silently change what it accepts."* Sound for the
firmware, bad for a pilot — `Power::calcMotorTempLimit` returns 0 outright when
`reductionStart == maxTemp`, and `constrain(..., 0, 100)` pins it to 0 when
start is above max. Either way power is cut from the reduction start upward, so
`start 20 °C, max 10 °C` makes the motor unusable above 20 °C and that is found
on takeoff.

So the form refuses to produce it. **Do not "align" the two files by deleting
the ordering rules.** The divergence is the point, and it covers only values
nobody wants.

**`ErrBadArg` is the only detector of real drift.** Nothing checks that the two
copies agree, so a write the app accepted and the firmware refused means the
mirrored ranges have moved apart. It is reported as that, not as a pilot error.

### Settings is the only way out of the flight screen

The entry sits in the "MAIS DADOS" drawer — already outside the card stack,
already opened deliberately — and is **disabled with its reason** while armed
or on a connection with no request channel, rather than hidden. Fixed presence,
varying state, the same rule the status chips follow.

A gate the pilot sees before acting beats an `ErrState` arriving after the tap.
The screen itself also disables saving if the aircraft arms while it is open.

After a successful write the app **re-reads the group** instead of trusting the
values it just sent, because the band on the dials is drawn from them and
assumed data is what this codebase refuses everywhere else. A failed re-read is
still a success — the controller accepted the write; only the confirmation is
missing.

### The Dart enum order does not match the firmware's

`MotorTempSource` is declared `{can, ntc, none}` here; the firmware's
`MotorTempOrigin` is `{None = 0, Can = 1, Ntc = 2}`. The codec maps it with an
explicit `switch` and must never index one by the other's integer.
`DisarmReason` *is* positional, with a trailing `unknown` this repo adds so a
reason from newer firmware degrades instead of throwing.

## Project Structure

```
lib/
├── protocol/   xctod_frame.dart · xctod_parser.dart · line_assembler.dart
├── state/      link_health.dart · telemetry_repository.dart
│               ble_permission_policy.dart
├── ble/        fly_controller_link.dart · android_host.dart
└── ui/         app.dart · connection_screen.dart · flight_screen.dart
                widgets/dial.dart
```

The layering is the point, and it is worth preserving:

- **`protocol/`**, **`state/link_health.dart`** and
  **`state/ble_permission_policy.dart`** import nothing from
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

### The connection screen is a door, not a fallback

The pilot taps **Conectar**; the radio does not start itself. Once the first
frame has arrived the app never shows that screen again — a dropped link is
the flight screen's stale state, because swapping the instrument panel for a
logo mid-flight is the worst possible moment to change what is on screen.

That rule is enforced by an *absence*: `TelemetryRepository._onStatus` resets
`LinkHealth` only on `idle`, never on `disconnected`. With the last frame
surviving a drop, `isStale` stays true and `FlyApp`'s `frame == null &&
!isStale` stops being satisfied on its own. There is no "has flown" flag, and
there must not be one.

Putting `_health.reset()` back on the `disconnected` branch looks like fixing
a leak and is the bug. `test/state/telemetry_repository_test.dart` exists to
catch that.

The button becomes **Cancelar** while trying, because `connect()` retries
forever with a backoff and there is no failure state to fall into. Giving up
automatically was rejected: the pilot may be walking to a controller that is
still powered off, which is exactly what the 8 s backoff cap was written for.

### MTU

The MTU is requested **as an argument to `connect()`**, not separately.
`flutter_blue_plus` negotiates it during connection and skips the exchange on
iOS, where CoreBluetooth owns the value and settles on 185 by itself, so there
is no platform branch to write. Calling `requestMtu` afterwards is not just
redundant — the plugin's own default is 512, so a later call at 247 *lowers*
what was already granted. Measured, in that order, on a Galaxy A12.

Android's default ATT MTU is 23, which caps a notification at 20 bytes and
would truncate every ~90-byte sentence. **Verified on Android 12: 247 granted,
`status=0`, panel live, zero rejected frames.**

Frames that fail the 16-field count are counted and the total is shown on the
connection screen. Non-zero there with no telemetry is the signature of an MTU
that never grew — which is why it is surfaced rather than silenced.

### A scan that finds nothing has to end itself

`FlutterBluePlus.scanResults` is process-wide and **never closes**: `stopScan`
cancels the plugin's internal subscriptions and emits nothing, and the scan
timeout is only `Timer(timeout, stopScan)`. So a loop that awaits results
alone hangs forever the moment a window expires — no retry, no error, the
pilot left on "Procurando o controlador…" until the app is force-stopped.
That shipped, and it is what made the app look broken on Android while the
iPhone connected: not a platform difference, a state the iPhone happened not
to step in.

`_scanForController` therefore watches `isScanning` going false as the end of
an unsuccessful attempt, subscribed *after* `startScan` because it re-emits
its current value. It also uses `onScanResults` rather than `scanResults`,
because the latter replays the previous scan's last value to a new listener —
enough to "find" a controller that has since been switched off.

Names are matched against `platformName` **or** `advName`. The first is the
name the OS has cached (`BluetoothDevice.getName()` on Android, empty for a
device never bonded with); the second is the one in the advertisement.

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
red for armed, faults and the thermal cut, amber for the thermal reduction
ramp.

Amber was added for the ramp rather than a second opacity of red. Caution and
danger are different states and the instrument convention for them predates
this app by a long way; two alphas of one hue made the reader work out which
was which. It is `#D29922`, from the same Primer palette as the green and the
red, so it is not a colour picked in isolation.

### The logo is derived, not drawn

`assets/logo/aerovolt.svg` and `aerovolt_mark.svg` are **generated** by
`tool/generate_logo_assets.py` from `aerovolt_traced.svg`. Edit the script,
never the output.

The trace is a full-canvas black plate with the logo knocked out of it, so it
paints a black rectangle wherever it is placed. The script wraps its paths in
a `<mask>` and paints a `<rect>` through it, which inverts the polarity while
keeping the nonzero winding and the antialiasing intact. Deleting the plate
and switching to `fill-rule="evenodd"` looks equivalent and silently drops
shapes — it was tried.

Because a single `fill` carries the colour, one file serves any tint:
`AerovoltLogo` drives it from `colorScheme.onSurface`, and there is no
light/dark pair to keep in sync. The `viewBox` is normalised to the ink, so a
width means the width you see.

The icon masters in `tool/icons/` come from `tool/generate_icon_masters.py`,
which rasterises the mark with headless Chrome — there is no `cairosvg` or
`rsvg-convert` on this machine.

## Testing

```bash
flutter test                                  # everything
flutter test test/protocol/                   # the parser — where correctness lives
```

The parser suite is the real safety net: a corpus of real sentences plus
truncated lines, wrong field counts, an empty field in every position, every
disarm code, both motor-temp sources. It needs no hardware and runs instantly.

`test/state/ble_permission_policy_test.dart` is the Android counterpart: the
API ≤ 30 permission branch cannot be reached on a modern test phone, so the
table is the only thing that exercises it. `test/ble/android_host_test.dart`
mocks the platform channel, so even the seam is covered without a device.

What tests cannot cover, and must be checked on a device: MTU negotiation on
Android, coexistence with XCTrack connected at the same time, and the
permission dialogs actually appearing. All are open — see
[docs/ROADMAP.md](docs/ROADMAP.md).

## Conventions

- **Language:** code, comments, documentation and commit messages in
  **English**. User-facing strings in the UI are in **Brazilian Portuguese** —
  the same split as fly-controller.
- Commit messages carry the *why*, not a restatement of the diff.
- `docs/superpowers/` (specs and plans) is gitignored working material. Durable
  reasoning belongs in this file, in `docs/ROADMAP.md`, or in a commit message.

## Android

`minSdk` is **24**, and it is a floor rather than a preference. Flutter 3.47
(`gradle_utils.dart`), `permission_handler_android` and
`shared_preferences_android` each declare 24, so 23 fails the manifest merger
and `flutter install` refuses the device outright. The cost is Android 6
hardware — a Galaxy S5 tops out at API 23, one level short, and there is no
cheap way around it.

`compileSdk` is **37 with `compileSdkMinor = 0`**, pinned for every module in
`android/build.gradle.kts`. `permission_handler_android` needs API 37
(`VERSION_CODES.CINNAMON_BUN`, `ACCESS_LOCAL_NETWORK`), but Google publishes
that platform only as `platforms;android-37.0`, and a bare `compileSdk = 37`
makes AGP look for the hash `android-37` and fail on a healthy SDK. The block
must sit **above** `evaluationDependsOn(":app")`, which forces subproject
evaluation — an `afterEvaluate` registered after it throws.

### A BLE scan below API 31 is a location capability

`ACCESS_FINE_LOCATION` is declared with `maxSdkVersion="30"` and requested at
runtime only there, because `neverForLocation` on `BLUETOOTH_SCAN` replaces it
from 31. **Both halves fail silently if you get them wrong**, in opposite
directions:

- Ask for too little on API ≤ 30 and `permission_handler` reports
  `bluetoothScan` as *granted* — below 31 it maps to no runtime permission at
  all and only checks the manifest — so no dialog appears and `startScan`
  returns an empty list forever.
- Ask for location on API 31+, where the capped permission has been stripped
  by the OS, and an empty name list comes back as `DENIED`, so the app claims
  a refusal that never happened.

That is why `lib/state/ble_permission_policy.dart` is pure and table-tested at
24/26/28/29/30/31/33/36: the API ≤ 30 branch is the one the available test
device does not run, so the table is the only thing keeping it correct. The
runtime API level comes from a two-method channel in `MainActivity.kt` —
`device_info_plus` would be a fifth dependency, on every platform, to read one
integer.

`bluetoothOff` and `locationOff` are link statuses for the same reason: each
needs something different from the pilot, and all three otherwise look
identical from outside — a scan that finds nothing.

### Back does not leave the flight screen

It closes the secondary-data overlay, which is a `Stack` child rather than a
route and therefore has no route for back to pop; unguarded, back popped the
app. `canPop` stays false with the overlay closed too — leaving mid-flight is
home or the app switcher, deliberately.

### Signing

Release builds are signed from a gitignored `android/key.properties` pointing
at a keystore outside the repo, falling back to debug keys when it is absent
so a fresh clone still builds. **The key is what lets an APK install over the
copy a pilot already has**; a different key means uninstall first, and the
stored pack/per-cell preference goes with it. Losing it means every user
reinstalls. Generated in Play upload-key form in case that is ever needed.

## iOS

Signed with a **free personal Apple ID** (team `KP44BA9VNZ`, bundle
`br.com.medeirostec.aerovolt`), so:

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
use. **Commercial use requires `License.commercial`, a paid licence.**
If this app is ever sold, bundled with a controller sold for profit, or shipped
by a company, that has to be dealt with first.

The licence (FlutterBluePlus License v1.5, in the package's `LICENSE`) turns on
**for-profit use and nothing else** — it says nothing about distribution or how
many people receive the app, so handing free APKs to other pilots stays inside
the free tier. Section 3 covers "commercial use by individuals" too, at
US$ 999 one-time for the Inventor tier on the payment portal; note that tier is
absent from the licence text, which lists only Starter (US$ 2,999) upward.
Section 1.4 also permits a **build-time** telemetry ping carrying the package
name, app name and version — nothing from end users, and it does not reach the
shipped app.

## What is deliberately absent

Not oversights — this data does not exist on the `$XCTOD` stream, and is
available only when the binary service is present:

- **Flight clock** (`sessionSec`) — **done**, shown in the status row
- **Which limiter is acting** (`limitCauses`) — **done**, named on the chip
- **The red reduction band** on the thermal dials — **done**, from `CFG_GET`

Still absent:

- **Buzzer mirroring** — needs `EVT_BEEP` playback off the `RSP` event stream,
  which `ControlSession` already separates and discards. Phase 2, subsystem 5.
