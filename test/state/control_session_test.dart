import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/state/control_session.dart';

/// Stands in for the radio. Records what was sent and lets a test push a
/// response back whenever it likes.
class FakeTransport {
  final sent = <List<int>>[];
  final _incoming = StreamController<List<int>>.broadcast();
  bool failNextSend = false;

  Stream<List<int>> get incoming => _incoming.stream;

  Future<void> send(List<int> bytes) async {
    if (failNextSend) {
      failNextSend = false;
      throw StateError('write failed');
    }
    sent.add(bytes);
  }

  /// Echoes a reply for the request at [index], with the sequence it carried.
  void reply(int index, {int status = 0, List<int> payload = const []}) {
    final req = sent[index];
    _incoming.add([req[0], req[1], status, payload.length, ...payload]);
  }

  void push(List<int> frame) => _incoming.add(frame);

  Future<void> close() => _incoming.close();
}

void main() {
  late FakeTransport transport;
  late ControlSession session;

  setUp(() {
    transport = FakeTransport();
    session = ControlSession(
      transport.send,
      incoming: transport.incoming,
      timeout: const Duration(milliseconds: 50),
    );
  });

  tearDown(() async {
    session.dispose();
    await transport.close();
  });

  group('sequence allocation', () {
    test('starts at 1, because zero is reserved for events', () async {
      unawaited(session.request(op: 0x10));
      await pumpEventQueue();
      expect(transport.sent.single[1], 1);
    });

    test('counts upward and never emits zero', () async {
      for (var i = 0; i < 300; i++) {
        unawaited(session.request(op: 0x10));
        await pumpEventQueue();
        transport.reply(i);
        await pumpEventQueue();
      }
      final seqs = transport.sent.map((f) => f[1]).toList();
      expect(seqs, isNot(contains(0)));
      expect(seqs.first, 1);
      // Wrapped past 255 and kept going.
      expect(seqs.length, 300);
    });
  });

  group('matching', () {
    test('a reply completes its own request with the payload', () async {
      final future = session.request(op: 0x10, payload: const [0x01]);
      await pumpEventQueue();
      transport.reply(0, payload: const [0xAA, 0xBB]);

      final result = await future;
      expect(result, isA<ControlOk>());
      expect((result as ControlOk).payload, [0xAA, 0xBB]);
    });

    test('two requests in flight each get their own reply', () async {
      final a = session.request(op: 0x10, payload: const [0x00]);
      await pumpEventQueue();
      final b = session.request(op: 0x10, payload: const [0x01]);
      await pumpEventQueue();

      // Answered out of order on purpose.
      transport.reply(1, payload: const [0xBB]);
      transport.reply(0, payload: const [0xAA]);

      expect(((await a) as ControlOk).payload, [0xAA]);
      expect(((await b) as ControlOk).payload, [0xBB]);
    });

    test('a non-zero status becomes a refusal, not a payload', () async {
      final future = session.request(op: 0x11);
      await pumpEventQueue();
      transport.reply(0, status: 2); // ErrBadOp

      final result = await future;
      expect(result, isA<ControlRefused>());
      expect((result as ControlRefused).status, ControlStatus.errBadOp);
    });

    test('a reply for a sequence nobody is waiting on is dropped', () async {
      // The late-response case: completing anything with it would be worse
      // than ignoring it.
      transport.push([0x10, 0x77, 0x00, 0x00]);
      await pumpEventQueue();

      final future = session.request(op: 0x10);
      await pumpEventQueue();
      transport.reply(0);
      expect(await future, isA<ControlOk>());
    });

    test('a malformed frame is ignored, not matched', () async {
      final future = session.request(op: 0x10);
      await pumpEventQueue();
      transport.push([0x10]); // shorter than a header
      await pumpEventQueue();
      transport.reply(0);
      expect(await future, isA<ControlOk>());
    });
  });

  group('events', () {
    test('seq zero reaches the event stream and completes nothing', () async {
      final events = <ControlResponse>[];
      session.events.listen(events.add);

      final future = session.request(op: 0x10);
      await pumpEventQueue();

      transport.push([0x80, 0x00, 0x00, 0x01, 0x42]); // EVT_BEEP, seq 0
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.op, 0x80);
      expect(events.single.payload, [0x42]);

      transport.reply(0);
      expect(await future, isA<ControlOk>(),
          reason: 'the event must not have consumed the pending request');
    });
  });

  group('failure', () {
    test('no reply within the timeout gives ControlTimeout', () async {
      final result = await session.request(op: 0x10);
      expect(result, isA<ControlTimeout>());
    });

    test('a reply arriving after the timeout completes nothing', () async {
      final result = await session.request(op: 0x10);
      expect(result, isA<ControlTimeout>());
      // Would throw "Future already completed" if the entry had survived.
      transport.reply(0);
      await pumpEventQueue();
    });

    test('a send that throws fails the request immediately', () async {
      transport.failNextSend = true;
      expect(await session.request(op: 0x10), isA<ControlDropped>());
    });

    test('dispose fails every pending request with Dropped', () async {
      final a = session.request(op: 0x10);
      final b = session.request(op: 0x11);
      await pumpEventQueue();

      session.dispose();

      expect(await a, isA<ControlDropped>());
      expect(await b, isA<ControlDropped>());
    });

    test('a request after dispose is Dropped, not a hang', () async {
      session.dispose();
      expect(await session.request(op: 0x10), isA<ControlDropped>());
    });
  });
}
