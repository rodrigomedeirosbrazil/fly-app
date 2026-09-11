import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_frame.dart';

void main() {
  group('encodeCommand', () {
    test('lays out op, seq, len and payload in that order', () {
      expect(
        encodeCommand(op: 0x10, seq: 1, payload: const [0x01]),
        [0x10, 0x01, 0x01, 0x01],
      );
    });

    test('an empty payload still carries a zero length', () {
      expect(encodeCommand(op: 0x20, seq: 7), [0x20, 0x07, 0x00]);
    });

    test('refuses a payload the firmware queue would silently drop', () {
      // CONTROL_QUEUED_PAYLOAD_MAX is 32. A longer request is discarded by
      // ControlRequestQueue::push with no reply, so catching it here turns a
      // mystery timeout into a programming error.
      expect(
        () => encodeCommand(op: 0x11, seq: 1, payload: List.filled(33, 0)),
        throwsArgumentError,
      );
      expect(
        encodeCommand(op: 0x11, seq: 1, payload: List.filled(32, 0)).length,
        3 + 32,
      );
    });
  });

  group('decodeResponse', () {
    test('reads op, seq, status and payload', () {
      final r = decodeResponse([0x10, 0x05, 0x00, 0x02, 0xAA, 0xBB])!;
      expect(r.op, 0x10);
      expect(r.seq, 5);
      expect(r.status, ControlStatus.ok);
      expect(r.payload, [0xAA, 0xBB]);
    });

    test('a response with no payload is still a response', () {
      final r = decodeResponse([0x01, 0x02, 0x00, 0x00])!;
      expect(r.status, ControlStatus.ok);
      expect(r.payload, isEmpty);
    });

    test('every status code maps', () {
      const expected = [
        ControlStatus.ok,
        ControlStatus.errAuth,
        ControlStatus.errBadOp,
        ControlStatus.errBadArg,
        ControlStatus.errState,
        ControlStatus.errBusy,
      ];
      for (var i = 0; i < expected.length; i++) {
        expect(decodeResponse([0x10, 0x01, i, 0x00])!.status, expected[i],
            reason: 'status $i');
      }
    });

    test('an unknown status degrades rather than throwing', () {
      expect(decodeResponse([0x10, 0x01, 99, 0x00])!.status,
          ControlStatus.unknown);
    });

    test('a frame shorter than the header is rejected', () {
      expect(decodeResponse([]), isNull);
      expect(decodeResponse([0x10, 0x01, 0x00]), isNull);
    });

    test('a len longer than the bytes received is rejected', () {
      // Truncation, not a short payload: decoding it would hand the caller a
      // config group with its tail missing.
      expect(decodeResponse([0x10, 0x01, 0x00, 0x04, 0xAA]), isNull);
    });

    test('trailing bytes beyond len are ignored, not rejected', () {
      final r = decodeResponse([0x10, 0x01, 0x00, 0x01, 0xAA, 0xFF, 0xFF])!;
      expect(r.payload, [0xAA]);
    });

    test('seq zero marks an event, not a reply', () {
      expect(decodeResponse([0x80, 0x00, 0x00, 0x00])!.isEvent, isTrue);
      expect(decodeResponse([0x10, 0x01, 0x00, 0x00])!.isEvent, isFalse);
    });
  });
}
