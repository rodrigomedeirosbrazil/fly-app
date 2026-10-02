import 'dart:typed_data';

/// `SET_TIME`. Payload is the instant as epoch milliseconds, int64
/// little-endian — the same number the web portal posts as text to
/// `/api/settime`.
///
/// The controller's only clock consumer is its `Logger`, which dates file
/// names and stamps rows in UTC via `gmtime_r`. It has no battery-backed
/// clock, so the time is lost on every power cycle.
const int kOpSetTime = 0x27;

/// The 8-byte `SET_TIME` payload for [t].
///
/// Epoch milliseconds are UTC by definition, so the phone's time zone does
/// not reach the controller.
Uint8List encodeSetTime(DateTime t) {
  final d = ByteData(8)..setInt64(0, t.millisecondsSinceEpoch, Endian.little);
  return d.buffer.asUint8List();
}
