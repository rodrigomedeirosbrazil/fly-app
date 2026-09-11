import '../protocol/telemetry_frame.dart';

/// Decides whether the telemetry on screen is still true.
///
/// Pure: no Flutter, no timers, no ambient clock. Every method takes the
/// current time so the whole thing is testable without waiting.
class LinkHealth {
  LinkHealth({this.staleAfter = const Duration(seconds: 3)});

  /// The controller notifies once per second. Three seconds is three missed
  /// notifications — long enough not to flicker, short enough that a pilot
  /// never reads a stale number as current.
  final Duration staleAfter;

  TelemetryFrame? _last;
  int _rejected = 0;

  /// Payloads received that did not decode. Surfaced in the UI rather than
  /// silenced: on Android this is the symptom of an MTU that never grew.
  int get rejectedCount => _rejected;

  /// Feeds one decoded frame, or null when the payload was rejected.
  ///
  /// Decoding happens above this class now: two sources produce the same
  /// model, and which decoder ran is not this class's business. Rejections are
  /// counted and deliberately do **not** refresh the clock — a stream of
  /// garbage has to age out exactly like silence.
  ///
  /// Takes no clock, unlike [frameAt] and [isStale]: freshness is measured
  /// from the frame's own `receivedAt`, never from when this was called.
  bool onFrame(TelemetryFrame? frame) {
    if (frame == null) {
      _rejected++;
      return false;
    }
    _last = frame;
    return true;
  }

  /// The current frame, or null once it is older than [staleAfter]. Withholding
  /// it is deliberate: no data beats stale data.
  TelemetryFrame? frameAt(DateTime now) {
    final f = _last;
    if (f == null) return null;
    if (now.difference(f.receivedAt) > staleAfter) return null;
    return f;
  }

  /// True when a frame was received but has since aged out — the difference
  /// between "signal lost" and "never connected".
  bool isStale(DateTime now) => _last != null && frameAt(now) == null;

  /// Drops the current frame.
  ///
  /// Call when the pilot has explicitly stopped — never on a dropped
  /// link. Surviving a drop is what makes [isStale] mean 'signal lost'
  /// rather than 'never connected', and what keeps the app from
  /// replacing the instrument panel with the connection screen in
  /// flight.
  void reset() => _last = null;
}
