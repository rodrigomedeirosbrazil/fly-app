# BLE DFU — the firmware side

**For:** `fly-controller`, branch `worktree-ble-control-service` or later
**Written by:** the `fly-app` side, which is implemented against this document
**Status:** specification. Nothing in fly-controller implements it yet.

The app can already transfer a firmware image and will not be able to prove it
until this exists. Where a choice here looks arbitrary, the reason is in
`fly-app`'s `docs/superpowers/specs/2026-09-11-ble-dfu-design.md`.

## Why bulk does not use `CMD`

`CONTROL_QUEUED_PAYLOAD_MAX` is 32 bytes and `ControlRequestQueue` is four
deep and drops the newest on overflow. A 1.8 MB image through it is ~57,000
round trips. So control uses `CMD`/`RSP` and bulk gets the characteristic the
protocol already reserved.

## The characteristic

| | |
|---|---|
| UUID | `D4CF0006-9B9D-4BFD-8F7F-40C6989D3EA9` |
| Properties | **write without response** |
| Payload | `[offset u32 LE][data…]` |

Write-without-response is what makes the transfer take a minute rather than
ten. It guarantees nothing, which is why the offset is absolute and in every
packet and the image carries a CRC32.

**It must be added to the existing control service.** The app treats it as
optional and works without it, so adding it breaks no client.

## The opcodes

Reserved range `0x50–0x5F`.

| Op | Name | Payload → Response | Auth | While armed |
|---|---|---|---|---|
| `0x50` | `DFU_BEGIN` | `[size u32][crc32 u32]` → `[chunkSize u16]` | yes | **refused** |
| `0x51` | `DFU_COMMIT` | — → — | yes | **refused** |
| `0x52` | `DFU_ABORT` | — → — | yes | **refused** |
| `0x53` | `DFU_STATUS` | — → `[state u8][received u32][chunkSize u16]` | **no** | allowed |

`DFU_STATUS` joins `CfgGet` and `BmsScanStatus` in `opRequiresAuth`'s exempt
list and in `opAllowedWhileArmed`: it is a plain getter, and the app polls it
once a second during a transfer.

The other three are ordinary writes, so `gateRequest()` already refuses them
while armed and reports that **before** auth — which is what stops the app
asking for a PIN to do something refused anyway.

`state`: `0` idle · `1` receiving · `2` verifying · `3` ready · `4` error.

`chunkSize` is the **usable** bytes per data packet — the negotiated ATT MTU
minus 3. The app subtracts 4 more for the offset and sends that many image
bytes per packet.

## `DFU_BEGIN` must answer before it erases

This is the instruction most likely to be got wrong, and the failure is
confusing on both sides.

Erasing an OTA slot is 1.875 MB of flash and blocks for **seconds**. If it
runs inline in the request handler:

- it can outlast `WDT_TIMEOUT_S` (10 s, `panic=true`) and **reboot the
  controller**, and
- it will certainly outlast the app's **2 s** request timeout, so a controller
  that is working correctly looks dead.

So: validate, answer `Ok` with the chunk size, set `state = receiving`, and
**erase from the loop task afterwards**. Data packets that arrive during the
erase are dropped — the app restarts from the acknowledged offset, so nothing
is lost but time.

Validation before answering:

- `size` must be non-zero and no larger than one slot (`0x1E0000`)
- refuse with `ErrBadArg` otherwise

## Receiving

Track the **highest contiguous offset written**. That single number is what
`DFU_STATUS.received` reports and what the app trusts for progress.

A packet whose offset is not exactly `received` is **dropped, not buffered**.
The app restarts from `received` rather than expecting repair, so
out-of-order retention would be complexity serving nobody. A packet at an
offset below `received` is a resend of something already written; drop it too.

`Update.write()` is already used by the portal
(`src/WebServer/ControllerWebServer.cpp:1060`) and is the natural sink.

## `DFU_COMMIT`

Refuse with `ErrState` unless `received == size` **and** the CRC32 over what
was written matches the one from `DFU_BEGIN`. Computing it over the written
image — reading the OTA partition back — is what makes this an integrity
check rather than a checksum of a buffer that is already gone.

On success: `Update.end(true)`, answer `Ok`, then reboot. Answer first; a
reboot before the notification leaves the app reporting a failure on an update
that worked.

## `DFU_ABORT`

`Update.abort()`, state back to `idle`, `received` to zero. Must be safe at
any point, including before `DFU_BEGIN`.

## What this cannot check, and neither can the app

Nothing in an ESP32 image says which controller it is for. XAG and Tmotor run
different builds and both pass the magic byte, the size and the CRC. The app
warns the pilot in as many words, and the recovery is a USB cable.

**A `boardId` in `INFO` plus a matching marker in the image would fix it
properly.** That is a separate change and worth making: it is the difference
between a bad update being refused and a bad update being discovered by a
controller that will not boot.

## Verification, once it exists

- A transfer completes and `INFO.appVersion` changes after commit
- **Walk out of range mid-transfer**: the controller keeps running the old
  firmware, and the next `DFU_STATUS` after reconnecting still reports a
  sensible `received`
- Arm mid-transfer: `DFU_COMMIT` is refused with `ErrState`
- A corrupted image fails at commit, and the controller still boots
- Time it, so the app can stop guessing at "60–120 s"
