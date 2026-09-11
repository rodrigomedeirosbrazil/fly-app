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

A binary telemetry characteristic (roughly 200 B of CSV becomes ~40 B, and it
can carry fields the sentence has no room for), plus a command characteristic
and a config characteristic. `Xctod` stays up for XCTrack.

This is what unlocks the four things the panel is visibly missing: the flight
clock, which limiter is acting, the thermal reduction band on the dials, and
buzzer mirroring.

**Blocked on flash.** The likely payment is porting Bluedroid → **NimBLE**
(`Xctod` plus the three BMS backends), worth roughly 100–200 KB and some RAM.

### Phase 3 — firmware update over BLE

A DFU characteristic writing into `esp_ota_write()`, using the dual-slot scheme
that already exists. Additive in flash terms.

The alternative considered and set aside: handing off to the existing WiFi AP,
which would be ~10 s instead of ~60–120 s and cost almost no firmware, but
needs `NEHotspotConfiguration` on iOS (an Apple entitlement), drops the phone's
internet, and contradicts the brief that access is over Bluetooth.

### Phase 4 — retire the web portal

Frees 200–400 KB (ESPAsyncWebServer + ElegantOTA + the gzipped assets). This is
what makes the flash arithmetic work overall: phase 4 returns more than phases
2–3 spend. The catch is that the debt has to be paid before it is earned.

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

**Does phase 2 extend the NUS service or add a second one?**

**Does phase 3's OTA go over BLE or hand off to WiFi?** BLE in principle; the
throughput actually observed may reopen it.

## Known issues in fly-controller

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
