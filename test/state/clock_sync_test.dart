import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/protocol/set_time.dart';
import 'package:fly_app/state/clock_sync.dart';
import 'package:fly_app/state/control_session.dart';

import 'fake_session.dart';

/// A session whose single request never answers until the test says so.
class HangingSession implements ControlSession {
  final sent = <({int op, List<int> payload})>[];
  final _reply = Completer<ControlResult>();

  void answer(ControlResult r) => _reply.complete(r);

  @override
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) {
    sent.add((op: op, payload: payload));
    return _reply.future;
  }

  @override
  Stream<ControlResponse> get events => const Stream.empty();

  @override
  Duration get timeout => const Duration(seconds: 2);

  @override
  void dispose() {}
}

void main() {
  late FakeSession session;
  late DateTime now;
  late ClockSync sync;

  setUp(() {
    session = FakeSession();
    now = DateTime.utc(2026, 10, 2, 12);
    sync = ClockSync(session, now: () => now);
  });

  test(
    'the first disarmed frame sends SET_TIME with the current time',
    () async {
      session.queueOk();
      sync.onFrame(armed: false);
      await pumpEventQueue();

      expect(session.sent, hasLength(1));
      expect(session.sent.single.op, kOpSetTime);
      expect(session.sent.single.payload, encodeSetTime(now));
    },
  );

  test('armed frames send nothing; the first disarmed one does', () async {
    // A pilot who connects to an armed aircraft is synced the moment they
    // disarm, not never.
    sync.onFrame(armed: true);
    sync.onFrame(armed: true);
    await pumpEventQueue();
    expect(session.sent, isEmpty);

    session.queueOk();
    sync.onFrame(armed: false);
    await pumpEventQueue();
    expect(session.sent, hasLength(1));
  });

  test('once it succeeds, later frames send nothing', () async {
    session.queueOk();
    sync.onFrame(armed: false);
    await pumpEventQueue();

    sync.onFrame(armed: false);
    sync.onFrame(armed: false);
    await pumpEventQueue();
    expect(session.sent, hasLength(1));
  });

  test('a frame while the request is in flight sends nothing', () async {
    // Frames arrive at 1 Hz and a request with retries can take 6 s.
    final hanging = HangingSession();
    final s = ClockSync(hanging, now: () => now);

    s.onFrame(armed: false);
    s.onFrame(armed: false);
    s.onFrame(armed: false);
    await pumpEventQueue();
    expect(hanging.sent, hasLength(1));

    hanging.answer(const ControlOk([]));
    await pumpEventQueue();
    s.onFrame(armed: false);
    await pumpEventQueue();
    expect(hanging.sent, hasLength(1));
  });

  test('a timeout retries with a fresh time, not the stale bytes', () async {
    // Resending the original payload after a 2 s timeout would set the
    // controller 2 s slow. FakeSession answers Timeout when nothing is queued.
    final times = [
      DateTime.utc(2026, 10, 2, 12, 0, 0),
      DateTime.utc(2026, 10, 2, 12, 0, 2),
      DateTime.utc(2026, 10, 2, 12, 0, 4),
    ];
    var i = 0;
    final s = ClockSync(session, now: () => times[i++]);
    session.queue(const ControlTimeout());
    session.queue(const ControlTimeout());
    session.queueOk();

    s.onFrame(armed: false);
    await pumpEventQueue();

    expect(session.sent.map((r) => r.payload).toList(), [
      encodeSetTime(times[0]),
      encodeSetTime(times[1]),
      encodeSetTime(times[2]),
    ]);
  });

  test('three timeouts and it stops for this connection', () async {
    sync.onFrame(armed: false); // queue empty: every attempt times out
    await pumpEventQueue();
    expect(session.sent, hasLength(ClockSync.maxAttempts));

    sync.onFrame(armed: false);
    await pumpEventQueue();
    expect(session.sent, hasLength(ClockSync.maxAttempts));
  });

  test(
    'ErrState (armed in between) retries on the next disarmed frame',
    () async {
      session.queue(const ControlRefused(ControlStatus.errState));
      sync.onFrame(armed: false);
      await pumpEventQueue();
      expect(
        session.sent,
        hasLength(1),
        reason: 'a refusal is an answer, not a timeout to retry',
      );

      session.queueOk();
      sync.onFrame(armed: false);
      await pumpEventQueue();
      expect(session.sent, hasLength(2));
    },
  );

  for (final status in [
    ControlStatus.errAuth, // firmware from before SET_TIME went PIN-free
    ControlStatus.errBadOp,
    ControlStatus.errBadArg,
    ControlStatus.errBusy,
  ]) {
    test('$status stops silently for this connection', () async {
      session.queue(ControlRefused(status));
      sync.onFrame(armed: false);
      await pumpEventQueue();

      sync.onFrame(armed: false);
      await pumpEventQueue();
      expect(
        session.sent,
        hasLength(1),
        reason: 'never a PIN prompt, never a second try',
      );
    });
  }

  test('a dropped link stops it', () async {
    session.queue(const ControlDropped());
    sync.onFrame(armed: false);
    await pumpEventQueue();

    sync.onFrame(armed: false);
    await pumpEventQueue();
    expect(session.sent, hasLength(1));
  });
}
