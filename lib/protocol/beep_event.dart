/// `EVT_BEEP` (`0x80`), the controller's buzzer mirrored over `RSP`.
///
/// The **fifth** hand-duplicated fly-controller contract in this repo, after
/// the CSV sentence, the telemetry struct, the config groups and the
/// validation ranges. The definition of record is `ControlBeepEvent` in
/// `src/BleControl/ControlProtocol.h`; fields are read **by offset**, so a
/// field that moves in the firmware decodes silently into the wrong column
/// here.
///
/// Arrives with `seq = 0` on the wire — that is the *request* sequence,
/// reserved for unsolicited events. The `seq` in this payload is the sound
/// ring's own monotonic counter and lives in a different space. The firmware
/// already de-duplicates against a watermark before sending, so each event
/// arrives exactly once and this app must not invent a second watermark.
library;

import 'dart:typed_data';

/// Which layer a beep belongs to. They compose rather than queue: see
/// `state/buzzer_mirror.dart`.
enum BeepLayer {
  /// A finite pattern. Pauses a running state, plays, and the state resumes.
  event,

  /// A looping tone that is on until an `active: false` arrives.
  state,

  /// A layer this build does not know. Degrades instead of throwing, the same
  /// rule `DisarmReason` follows.
  unknown,
}

class BeepEvent {
  const BeepEvent({
    required this.seq,
    required this.frequency,
    required this.onMs,
    required this.offMs,
    required this.reps,
    required this.layer,
    required this.active,
  });

  final int seq;
  final int frequency;
  final int onMs;
  final int offMs;

  /// How many times the pattern repeats. **Zero means continuous.**
  final int reps;

  final BeepLayer layer;

  /// Started, rather than stopped. Only meaningful on [BeepLayer.state].
  final bool active;

  bool get isContinuous => reps == 0;

  static const int kLength = 13;

  static BeepEvent? decode(List<int> bytes) {
    if (bytes.length < kLength) return null;
    final d = ByteData.sublistView(Uint8List.fromList(bytes));
    return BeepEvent(
      seq: d.getUint32(0, Endian.little),
      frequency: d.getUint16(4, Endian.little),
      onMs: d.getUint16(6, Endian.little),
      offMs: d.getUint16(8, Endian.little),
      reps: d.getUint8(10),
      layer: switch (d.getUint8(11)) {
        0 => BeepLayer.event,
        1 => BeepLayer.state,
        _ => BeepLayer.unknown,
      },
      active: d.getUint8(12) != 0,
    );
  }
}

/// The `RSP` opcode carrying one of these.
const int kOpEvtBeep = 0x80;
