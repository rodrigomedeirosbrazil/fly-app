# Roadmap

Where this app is going, and why it is being built in this order. Written
2026-09-09, at the end of phase 1.

## The goal

Replace the controller's WiFi config portal. Today the only mobile-facing
interface is a browser at `192.168.4.1`, which means leaving the phone's
cellular network and typing an IP — unusable in flight and awkward on the
ground.

Getting there in one step is not viable, for two measured reasons:

- **Flash.** The XAG `firmware.bin` was 1,788,048 B of a 1,966,080 B app slot —
  **91%**. Each OTA slot already takes 1.875 MB of the 4 MB chip, so the
  partition cannot grow. There is roughly 87 KB of headroom.
- **The radio.** One ESP32-C3 antenna already runs a WiFi AP, ESP-NOW to the
  remote throttle, a BLE client to the BMS, and a BLE server for XCTrack. A
  second connected BLE central is an unmeasured risk.

So it is a ladder.

## Phases

### Phase 1 — read-only flight instrument · **done**

Consumes the `$XCTOD` sentence the controller already broadcasts for XCTrack.
**Zero firmware changes.** Shipped and running on an iPhone 14 Pro. Android
builds as a signed APK from the same source; not yet run on a phone.

The cheapest rung that answers the two questions gating every later one: does
the radio hold up with a phone connected, and is the app worth building a
protocol for.

### Phase 2 — a real GATT service

**Telemetry is done** (2026-09-11). The app reads the binary `TELEMETRY`
characteristic when the service is present and falls back to `$XCTOD`
otherwise, which delivered the flight clock and the acting limiter. `CMD`,
`RSP`, config editing and buzzer mirroring are still open — they are what the
remaining two absent items need.

**The request channel is done** (2026-09-11). `CMD`/`RSP` with sequence
matching and timeouts, plus `CFG_GET`, which delivered the thermal reduction
band. Writes, the PIN session, config editing, the action opcodes and buzzer
mirroring are still open — and the firmware already serves all of them, so
from here the app is the lagging side of phase 2.

**Configuration writes are done** (2026-09-11). The `Power` and `Thermal`
groups can be changed from the app, authenticated per connection with the
controller's PIN.

**BMS and System are done** (2026-09-11). The BMS type and address come from a
controller-driven scan, and the remote throttle pairs from the app. That closes
every value the web portal writes except the PIN itself, and leaves buzzer
mirroring as the last of phase 2.

Two things the app refuses to do, both recorded in `CLAUDE.md`: it never sends
`BMS_DETECT`, whose blocking connect can outlast the 10 s watchdog and reboot
the controller, and it never claims to cancel a pairing, because the protocol
has no opcode that does.

**Buzzer mirroring is done** (2026-09-11), and with it **phase 2's telemetry
is complete**. Every reading the binary service carries now reaches the pilot,
and nothing on the "deliberately absent" list is absent.

Latency is unmeasured and will be audible: a beep travels a 1 Hz firmware
loop, a BLE notification, a decode and an audio session before it sounds. Fine
for a warning, useless for anything the pilot times.

What phase 2 still does not send is `SET_TIME` (`0x27`), `PIN_CHANGE` (`0x28`)
and the two Tmotor direction opcodes — none of them telemetry, and
`PIN_CHANGE` alone deserves care because it is the one write that is **not
idempotent**, so it cannot use the retry every other write here depends on.

This is the first piece of the web portal with a real alternative, and
therefore the first step toward phase 4.

A binary telemetry characteristic (roughly 200 B of CSV becomes ~40 B, and it
can carry fields the sentence has no room for), plus a command characteristic
and a config characteristic. `Xctod` stays up for XCTrack.

This is what unlocks the four things the panel is visibly missing: the flight
clock, which limiter is acting, the thermal reduction band on the dials, and
buzzer mirroring.

**Blocked on flash.** The likely payment is porting Bluedroid → **NimBLE**
(`Xctod` plus the three BMS backends), worth roughly 100–200 KB and some RAM.

### Phase 3 — firmware update over BLE · **next**

A DFU characteristic writing into `esp_ota_write()`, using the dual-slot scheme
that already exists. Additive in flash terms.

Moved ahead of everything else by the pilot (2026-09-11): it is the capability
they want most, and unlike log download it removes a reason to open the portal
at all.

The alternative considered and set aside: handing off to the existing WiFi AP,
which would be ~10 s instead of ~60–120 s and cost almost no firmware, but
needs `NEHotspotConfiguration` on iOS (an Apple entitlement), drops the phone's
internet, and contradicts the brief that access is over Bluetooth.

### Phase 4 — retire the web portal · **deferred, on purpose**

**Not planned work.** The pilot's decision (2026-09-11): the portal stays until
the app has been flown enough to trust, and retiring it is a later call made on
evidence rather than a milestone to aim at.

**Log download is out with it.** The `0x40–0x4F` opcode range and the
`D4CF0006-…` characteristic stay reserved and unimplemented on both sides.

Kept here because the flash arithmetic still depends on it: retiring the portal
frees 200–400 KB (ESPAsyncWebServer + ElegantOTA + the gzipped assets), which
is more than phases 2–3 spend. The debt is simply carried longer than the
original plan assumed.

## Decisions on record

| Decision | Why |
|---|---|
| **Flutter**, not React Native | `flutter_blue_plus` moves payloads as binary `Uint8List` over the platform channel; `react-native-ble-plx` marshals them as base64 strings across the JS bridge, which is a real cost for the ~3,600 chunked writes a 1.8 MB BLE OTA needs in phase 3. `CustomPainter` also maps onto the SVG dials the web panel already had. |
| **Separate repo** | Independent CI, versioning and toolchain, following the `fly-throttle` precedent. Accepted cost: the `$XCTOD` contract exists twice. |
| **Sideload**, no App Store | Android APK direct; iOS built locally with a free Apple ID. No $99/yr account until someone other than the author is flying with it. An APK expires never, unlike the 7-day iOS build, so Android is the cheaper side to hand to someone. |
| **Google Play deferred**, and it is not free to re-enter | The 2012 developer account was **closed on 2024-03-14 for inactivity**; the US$ 25 fee is not refundable and publishing needs a new account. A new *personal* account must run a closed test with 12 testers for 14 days before production. An *organization* account skips that but needs a legal entity — and declares a for-profit, which is the FlutterBluePlus Section 3 trigger at Starter (US$ 2,999) instead of Inventor (US$ 999). None of it is required for sideloading. |
| **No firmware change in phase 1** | Maximum information per unit of risk. |
| **Design for XCTrack coexistence**, decide later | Whether the app runs alongside XCTrack or replaces it is undecided; phase 1 leaves `Xctod` untouched so both stay possible. |

## Open questions

**Does the binary telemetry path work on real hardware?** **Yes — answered
2026-09-11**, on an iPhone 14 Pro against a controller running
`worktree-ble-control-service`. Every reading the struct carries rendered,
including the flight clock and the fields the drawer gained, and the
discarded-frame counter stayed at **zero**.

The same build was tested first against `main` firmware, which has no control
service, and fell back to `$XCTOD` with the panel rendering exactly as it did
in phase 1. That was the check most likely to be skipped and the only one that
proves the fallback survived the migration — service presence really is the
capability handshake.

Disconnecting left the flight panel showing stale data rather than returning
to the connection screen, so the absence in `TelemetryRepository._onStatus`
still does its job on a real link.

Three things this did **not** measure, and none of them are hypothetical:

- **The limiter chip has never fired.** No limiter acted during the test, so
  `BAT`/`MOT`/`ESC` on the status chip is covered by widget tests and nothing
  else. It needs a hot motor or a low pack.
- **Android has not seen the binary path at all.** The MTU answer below was
  measured against the ~90-byte `$XCTOD` sentence. The struct is 56 bytes and
  needs an ATT MTU of at least 59, where Android's default is 23 — the same
  negotiation, so the risk is low, but low is not measured. The
  discarded-frame counter is the instrument: non-zero there is an MTU that
  never grew.
- **The drawer was not opened in landscape**, which is the orientation whose
  height forced it to become scrollable.

**Is the firmware branch merged?** As of 2026-09-11, no. `b769fa1` lives on
`worktree-ble-control-service`. Nothing in the binary path has run on a
controller until it is.

**Does a write survive a power cycle?** Nothing has ever written to this
controller from the app. A `CFG_SET` returning `Ok` means the firmware accepted
it and the app confirms by re-reading, but neither proves it reached NVS rather
than RAM. Power-cycle the controller and check.

**Does the radio hold with the app connected?** Untested with XCTrack connected
at the same time, and untested with the ESP-NOW remote throttle also active —
that last one is the worst case for the single antenna. If XCTrack can be
retired, `Xctod` goes with it and phase 2's flash problem shrinks.

**Does MTU negotiation work on Android?** **Yes — answered 2026-09-10.**
Measured on a Galaxy A12 (SM-A125M, Android 12, API 31) against the
controller: `onConfigureMTU mtu=247 status=0`, the panel renders live
telemetry, and the discarded-frame counter stays at zero. This was the
specific failure phase 1 was built to measure, and it does not occur.

Getting there cost one real bug, which is the more useful finding: the app
could not connect on Android at all until `_scanForController` stopped
awaiting a stream `flutter_blue_plus` never closes. An empty 10-second scan
window left it hung with no retry — see `CLAUDE.md`.

**Does the app work on Android 7–11 at all?** Unknown, and it will stay that
way with the hardware on hand. The Galaxy A12 turned out to be on **API 31**,
so it takes the modern permission path and never executes the API ≤ 30 branch.
That branch is covered by a table test and by nothing else. Confirming it
needs an Android 7–11 device.

**The default voltage divider ratio is unreachable over BLE.**
`Settings::getDefaultVoltageDividerRatio()` returns `BATTERY_DIVIDER_RATIO`, a
compile-time constant per board, and it appears in neither `INFO` nor any
config group. The app can calibrate but cannot offer the portal's "Resetar
para Padrão". Exposing it would mean a byte in `INFO`, which is a protocol
change for a button.

**Does phase 2 extend the NUS service or add a second one?**

**Does phase 3's OTA go over BLE or hand off to WiFi?** BLE in principle; the
throughput actually observed may reopen it.

**How much flash did the control service actually cost?** `ROADMAP.md` still
describes phase 2 as blocked on flash, with a Bluedroid → NimBLE port as the
likely payment. The whole service shipped without that happening. The headroom
left in the 1.875 MB slot is unmeasured, and phase 3's OTA is additive — so
the number matters before it is planned.

## Known issues in fly-controller

**Changing the BMS type appears to clear the app's authentication.** Reported
from the aircraft: after authenticating, setting the type to Nenhum asked for
the PIN, and selecting a BMS again asked once more. `authenticated_` is only
cleared in `BleControl::onCentralDisconnected()`, which `BleServerHost`'s
`BLEServerCallbacks::onDisconnect` calls — so something in the BMS client's
connect/disconnect is reaching the *server's* disconnect callback. Worth
confirming with a log line in that callback: if it fires when no phone
disconnected, the callback is being invoked for the client role and the auth
reset belongs behind a check on which connection actually went away.

**The buzzer's gesture tones cannot be mirrored faithfully.** `Sound::handle()`
pushes a beep event when a state starts and nothing when `main.cpp` retunes it
via `setStateFreq()` on each on→off edge — so a BLE client is told 1800 Hz once
and never hears the arm-charge sweep. The app works around it by recomputing
the pitch from `armCharge`/`powerScale`, which duplicates `main.cpp`'s
arithmetic and steps at 1 Hz instead of ~10 Hz.

The clean fix is a **`uint16 stateFreqHz` appended to `ControlTelemetry`**: the
append rule already covers it, no version bump, and it removes a hand-copied
formula from fly-app. Pushing a beep event per retune would work too but
floods the eight-slot ring at ten events a second.

**A BMS scan races the BMS link it just tore down.** `startWebScan()` calls
`setEnabled(false)` on the three backends — which reaches
`pClient_->disconnect()` — and then `scan->start()` in the same loop
iteration. A BLE disconnect is asynchronous, so the scan begins while the
client link is still tearing down, and on a controller with a BMS configured
it commonly fails or finds nothing. Removing the configured BMS first is the
workaround, and it is what the app now tells the pilot to do. The fix belongs
in the firmware: wait for the disconnect before starting the scan.

**The scan's failure reason never reaches the app.** `getWebScanError()` holds
a string ("Failed to start BLE scan", "BLE stack is not initialized") that
`BMS_SCAN_STATUS` does not carry — the reply is `[status][count]` and results.
So the app can say a scan failed but never why. Worth appending to that reply.

**`REMOTE_FORGET` does not drop the running peer.** `Settings::clearRemoteMac()`
saves, but nothing tells `RemoteLink` to clear `peerMac_` or remove the ESP-NOW
peer, so a remote already transmitting may keep working until the controller
restarts. The app warns about this rather than working around it.

**A BMS scan alongside a second connected central is unmeasured.** Advertising
is suppressed for the 5 s a scan runs; XCTrack's existing link should survive,
but that is the firmware's claim and not yet a measurement.

**`REMOTE_FORGET` does not drop the running peer.** `Settings::clearRemoteMac()`
saves, but nothing tells `RemoteLink` to clear `peerMac_` or remove the ESP-NOW
peer, so a remote already transmitting may keep working until the controller
restarts. The app warns about this rather than working around it.

**A BMS scan alongside a second connected central is unmeasured.** Advertising
is suppressed for the 5 s a scan runs; XCTrack's existing link should survive,
but that is the firmware's claim and not yet a measurement.

Neither is fixed, and both belong to the other repo.

**The voltage decimal is wrong.** In `src/Xctod/Xctod.cpp`,
`writeBatteryInfo()` zero-pads the decimal only when it is below 10, but
`millivolts % 1000` spans 0–999. A pack at 50,040 mV is transmitted as `50.40`
instead of `50.040` — a +0.36 V error on roughly 10% of readings. This is wrong
for **XCTrack today**, not only for this app, and `docs/XCTOD-PROTOCOL.md`
documents the field as `V.mmm`, which the code does not deliver.

**The sentence now has a second positional consumer.** Until this app existed,
the only thing reading `$XCTOD` by column index was XCTrack, configured by hand
in a `.xcfg`. Now it is `lib/protocol/xctod_parser.dart`, in another
repository, with no shared package and no version handshake. Inserting a field
anywhere but the end shifts everything after it and this parser decodes into
the wrong columns without erroring. `fly-controller`'s `CLAUDE.md` and
`XCTOD-PROTOCOL.md` do not mention this app yet — they should.

**The protocol document contradicts itself on versioning.**
`docs/BLE-CONTROL-PROTOCOL.md` says to bump `CONTROL_PROTOCOL_VERSION`
"whenever an existing field moves", and separately that a higher version than
the client knows still works "because the append rule lets it". Both cannot
hold: if a field moved, appending saves nothing and the client decodes shifted
columns in silence — the exact `$XCTOD` hazard the binary protocol exists to
remove. This app gates on the telemetry struct's own `ver` instead, which is
scoped correctly. The document should say so; worth a PR against
fly-controller, because anyone writing another client will walk into it.

**The voltage decimal bug does not affect the binary path.**
`writeBatteryInfo()`'s zero-padding bug is still wrong for XCTrack and for this
app's fallback mode, but `batteryMv` is raw millivolts, so the panel is immune
whenever the control service is present.

## What phase 1 did not do

No writing to the controller, no commands, no OTA, no settings editing, no log
download, no buzzer mirroring, no background BLE, no app-store distribution, no
multi-controller pairing.
