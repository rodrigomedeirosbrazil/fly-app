import 'dart:async';

import '../protocol/control_frame.dart';
import '../protocol/set_time.dart';
import 'control_session.dart';

enum _Phase { idle, inFlight, done }

/// Sets the controller's clock once per connection, the way the web portal
/// does on every page load: automatically, with no prompt, and invisibly.
///
/// The controller has no battery-backed clock, and its `Logger` writes
/// `ms:<millis>` instead of a date until something sets one. One instance
/// per connection, created and discarded with the [ControlSession].
///
/// **It never prompts for a PIN.** `SET_TIME` needs none on current
/// firmware; older firmware answers `ErrAuth`, and that ends it silently —
/// the flight panel prompts for nothing, ever. Failure of any kind looks
/// exactly like the app before this existed: logs without dates.
class ClockSync {
  ClockSync(this._session, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// Attempts per connection when the controller does not answer.
  static const int maxAttempts = 3;

  final ControlSession _session;
  final DateTime Function() _now;
  _Phase _phase = _Phase.idle;

  /// Called on every decoded binary frame, not only the first: a connection
  /// that starts armed is synced on its first disarmed frame.
  ///
  /// Armed frames are skipped because the firmware refuses `SET_TIME` while
  /// armed: a clock jump mid-flight would split one flight's log across two
  /// time bases.
  void onFrame({required bool armed}) {
    if (_phase != _Phase.idle || armed) return;
    _phase = _Phase.inFlight;
    unawaited(_send());
  }

  Future<void> _send() async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      // Fresh every attempt: resending the first payload after a 2 s timeout
      // would set the controller 2 s slow. Setting the clock to "now" is
      // idempotent, which is why retrying is allowed at all.
      final result = await _session.request(
        op: kOpSetTime,
        payload: encodeSetTime(_now()),
      );
      if (result is ControlTimeout) continue;

      // ErrState means the aircraft armed between the frame and the request.
      // Going back to idle retries on the next disarmed frame, so it is
      // bounded by the 1 Hz telemetry and stops as soon as an armed frame
      // arrives. Every other answer — Ok, ErrAuth from older firmware,
      // ErrBadOp, a dropped link — ends it.
      _phase =
          result is ControlRefused && result.status == ControlStatus.errState
          ? _Phase.idle
          : _Phase.done;
      return;
    }
    _phase = _Phase.done;
  }
}
