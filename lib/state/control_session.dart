import 'dart:async';

import '../protocol/control_frame.dart';

/// The outcome of one request.
///
/// A sealed result rather than exceptions: `ErrBadOp` is the protocol's own
/// degrade-don't-hang mechanism — "this firmware cannot do that" — and making
/// callers catch it would be wrong about what it means.
sealed class ControlResult {
  const ControlResult();
}

class ControlOk extends ControlResult {
  const ControlOk(this.payload);
  final List<int> payload;
}

/// The controller answered and refused.
///
/// `errState` must never prompt for a PIN: the firmware's `gateRequest()`
/// reports armed *before* auth precisely so a client does not ask for a
/// password to do something that would be refused either way.
class ControlRefused extends ControlResult {
  const ControlRefused(this.status);
  final ControlStatus status;
}

/// Nothing came back. The only signal that exists for a malformed frame or a
/// full request queue — the firmware answers neither.
class ControlTimeout extends ControlResult {
  const ControlTimeout();
}

/// The link went away, or the write itself failed. Distinct from
/// [ControlTimeout] because a timeout is worth retrying and this is not.
class ControlDropped extends ControlResult {
  const ControlDropped();
}

/// One connection's worth of request/response traffic on `CMD`/`RSP`.
///
/// Pure: it takes a transport and knows nothing about BLE, which is what lets
/// timeouts and sequence races be tested in milliseconds with no radio.
///
/// **It never retries.** The channel cannot distinguish a lost request from a
/// slow one, and resending a non-idempotent operation — `PIN_CHANGE`,
/// `SESSION_RESET`, `BUZZER_PREVIEW` — would be a decision this class has no
/// information to make. Callers that know their request is idempotent retry
/// themselves.
class ControlSession {
  /// [send] writes one frame to the `CMD` characteristic. Positional so it can
  /// be an initializing formal for a private field: a named parameter cannot
  /// start with an underscore, and making the field public would expose a
  /// `send` that writes straight to the characteristic, bypassing the sequence
  /// allocation this class exists to do.
  ControlSession(
    this._send, {
    required Stream<List<int>> incoming,
    this.timeout = const Duration(seconds: 2),
  }) {
    _incomingSub = incoming.listen(_onFrame);
  }

  /// The firmware drains its queue in `handle()`, the same loop that emits
  /// telemetry at 1 Hz, so a reply arrives well inside this. Generous without
  /// approaching the 10 s task watchdog.
  final Duration timeout;

  final Future<void> Function(List<int>) _send;
  late final StreamSubscription<List<int>> _incomingSub;

  final _events = StreamController<ControlResponse>.broadcast();
  final _pending = <int, Completer<ControlResult>>{};
  final _timers = <int, Timer>{};

  /// Unsolicited frames — `RSP` with `seq` 0. Nothing consumes them yet, but
  /// the split has to exist: without it the first beep the firmware pushes
  /// would be matched as a reply to a request nobody made.
  Stream<ControlResponse> get events => _events.stream;

  /// Last sequence handed out. Counts upward and wraps, skipping 0.
  ///
  /// Never reusing a sequence early is not tidiness: a request that timed out
  /// may still have its reply in flight, and if that number had been handed
  /// out again the late reply would complete a different request with the
  /// wrong payload.
  int _lastSeq = 0;

  bool _disposed = false;

  int _nextSeq() {
    _lastSeq = _lastSeq >= 255 ? 1 : _lastSeq + 1;
    return _lastSeq;
  }

  /// Sends one request and waits for its reply.
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) async {
    if (_disposed) return const ControlDropped();

    final seq = _nextSeq();
    final completer = Completer<ControlResult>();
    _pending[seq] = completer;

    try {
      await _send(encodeCommand(op: op, seq: seq, payload: payload));
    } catch (_) {
      // The write never left. Waiting out the timeout would tell the caller
      // nothing it does not already know.
      _resolve(seq, const ControlDropped());
      return completer.future;
    }

    _timers[seq] = Timer(timeout, () => _resolve(seq, const ControlTimeout()));
    return completer.future;
  }

  void _onFrame(List<int> bytes) {
    final response = decodeResponse(bytes);
    if (response == null) return;

    if (response.isEvent) {
      _events.add(response);
      return;
    }

    _resolve(
      response.seq,
      response.status == ControlStatus.ok
          ? ControlOk(response.payload)
          : ControlRefused(response.status),
    );
  }

  /// Completes a pending request exactly once and forgets it. A reply whose
  /// sequence is not pending — the late-reply case — lands here and does
  /// nothing.
  void _resolve(int seq, ControlResult result) {
    _timers.remove(seq)?.cancel();
    _pending.remove(seq)?.complete(result);
  }

  /// Ends the session, failing every pending request with Dropped.
  ///
  /// Called when the link drops. Without it a pending request would wait a
  /// full timeout for a controller that is already gone, and a reply arriving
  /// after a reconnect could match a request from the previous connection.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();

    for (final completer in _pending.values) {
      completer.complete(const ControlDropped());
    }
    _pending.clear();

    _incomingSub.cancel();
    _events.close();
  }
}
