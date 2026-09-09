import '../protocol/xctod_frame.dart';
import '../protocol/xctod_parser.dart';

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

  XctodFrame? _last;
  int _rejected = 0;

  /// Lines received that did not decode. Surfaced in the UI rather than
  /// silenced: on Android this is the symptom of an MTU that never grew.
  int get rejectedCount => _rejected;

  /// Feeds one reassembled line. Returns true when it produced a usable frame.
  bool onLine(String line, DateTime now) {
    final frame = XctodParser.parse(line, receivedAt: now);
    if (frame == null) {
      _rejected++;
      return false;
    }
    _last = frame;
    return true;
  }

  /// The current frame, or null once it is older than [staleAfter]. Withholding
  /// it is deliberate: no data beats stale data.
  XctodFrame? frameAt(DateTime now) {
    final f = _last;
    if (f == null) return null;
    if (now.difference(f.receivedAt) > staleAfter) return null;
    return f;
  }

  /// True when a frame was received but has since aged out — the difference
  /// between "signal lost" and "never connected".
  bool isStale(DateTime now) => _last != null && frameAt(now) == null;

  /// Drops the current frame. Call on disconnect.
  void reset() => _last = null;
}
