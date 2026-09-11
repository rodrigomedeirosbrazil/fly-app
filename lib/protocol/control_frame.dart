import 'dart:typed_data';

/// Status byte of a `RSP` frame. Mirrors the firmware's `ControlStatus`.
///
/// [unknown] is this repo's own trailing member, so a status from a newer
/// firmware degrades instead of throwing — the same treatment `DisarmReason`
/// gets in `telemetry_frame.dart`.
enum ControlStatus { ok, errAuth, errBadOp, errBadArg, errState, errBusy, unknown }

/// `seq = 0` on `RSP` means "unsolicited event", never a reply. Request
/// senders therefore start at 1, which is what makes demultiplexing free.
const int kEventSeq = 0;

/// `CONTROL_QUEUED_PAYLOAD_MAX`. The firmware's request queue copies a
/// request's payload into a fixed 32-byte slot and **drops the whole request**
/// when it does not fit — with no reply, because the drop happens before any
/// dispatch. A caller would see only a timeout.
const int kMaxCommandPayload = 32;

/// One decoded `RSP` frame.
class ControlResponse {
  const ControlResponse({
    required this.op,
    required this.seq,
    required this.status,
    required this.payload,
  });

  final int op;
  final int seq;
  final ControlStatus status;
  final List<int> payload;

  /// True when this frame is an unsolicited event rather than a reply.
  bool get isEvent => seq == kEventSeq;
}

/// Builds a `CMD` frame: `[op][seq][len][payload]`.
///
/// Throws [ArgumentError] on an oversized payload rather than sending one:
/// the firmware would discard it silently and the caller would be left
/// blaming the radio for what is a programming error.
Uint8List encodeCommand({
  required int op,
  required int seq,
  List<int> payload = const [],
}) {
  if (payload.length > kMaxCommandPayload) {
    throw ArgumentError.value(
      payload.length,
      'payload',
      'exceeds the firmware queue slot of $kMaxCommandPayload bytes',
    );
  }
  final out = Uint8List(3 + payload.length);
  out[0] = op;
  out[1] = seq;
  out[2] = payload.length;
  out.setRange(3, out.length, payload);
  return out;
}

/// Decodes a `RSP` frame: `[op][seq][status][len][payload]`.
///
/// Returns null when the frame cannot be trusted. A `len` larger than the
/// bytes actually received is truncation, and handing the caller a config
/// group with its tail missing is the failure this guards against — the same
/// rule the telemetry codec applies to a short struct.
ControlResponse? decodeResponse(List<int> bytes) {
  if (bytes.length < 4) return null;

  final len = bytes[3];
  if (bytes.length < 4 + len) return null;

  return ControlResponse(
    op: bytes[0],
    seq: bytes[1],
    status: _status(bytes[2]),
    payload: List<int>.unmodifiable(bytes.sublist(4, 4 + len)),
  );
}

ControlStatus _status(int v) {
  final known = ControlStatus.values.length - 1; // excludes `unknown`
  return v < known ? ControlStatus.values[v] : ControlStatus.unknown;
}
