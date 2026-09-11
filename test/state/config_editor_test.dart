import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/state/control_session.dart';

/// Answers requests with whatever the test queued, in order.
class FakeSession implements ControlSession {
  final sent = <({int op, List<int> payload})>[];
  final _queued = <ControlResult>[];

  void queue(ControlResult r) => _queued.add(r);

  void queueOk([List<int> payload = const []]) => queue(ControlOk(payload));

  @override
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) async {
    sent.add((op: op, payload: payload));
    return _queued.isEmpty ? const ControlTimeout() : _queued.removeAt(0);
  }

  @override
  Stream<ControlResponse> get events => const Stream.empty();

  @override
  Duration get timeout => const Duration(seconds: 2);

  @override
  void dispose() {}
}

/// A valid 17-byte Thermal group: motor 80–100 °C, ESC 70–95 °C.
Uint8List thermalBytes({int motorStartMc = 80000}) {
  final d = ByteData(17);
  d.setInt32(0, motorStartMc, Endian.little);
  d.setInt32(4, 100000, Endian.little);
  d.setInt32(8, 70000, Endian.little);
  d.setInt32(12, 95000, Endian.little);
  return d.buffer.asUint8List();
}

const thermalPayload = ThermalConfig(
  motorReductionStartC: 80,
  motorMaxC: 100,
  escReductionStartC: 70,
  escMaxC: 95,
  motorTempSource: 0,
);

void main() {
  late FakeSession session;
  late ConfigEditor editor;

  setUp(() {
    session = FakeSession();
    editor = ConfigEditor(session);
  });

  group('the PIN is asked for lazily', () {
    test('a first save with no PIN asks for one and sends nothing', () async {
      final outcome = await editor.saveThermal(thermalPayload);

      expect(outcome, isA<SaveNeedsPin>());
      expect(session.sent, isEmpty,
          reason: 'nothing should reach the controller before authenticating');
    });

    test('a PIN authenticates, then the write goes out', () async {
      session.queueOk(); // AUTH
      session.queueOk(); // CFG_SET
      session.queueOk(thermalBytes()); // CFG_GET re-read

      final outcome = await editor.saveThermal(thermalPayload, pin: '1234');

      expect(outcome, isA<SaveOk>());
      expect(session.sent, hasLength(3));
      expect(session.sent[0].op, 0x01, reason: 'AUTH');
      expect(session.sent[0].payload, '1234'.codeUnits);
      expect(session.sent[1].op, 0x11, reason: 'CFG_SET');
      expect(session.sent[1].payload.first, ConfigGroup.thermal.id);
      expect(session.sent[2].op, 0x10, reason: 'CFG_GET re-read');
    });

    test('a second save on the same session does not ask again', () async {
      session.queueOk();
      session.queueOk();
      session.queueOk(thermalBytes());
      await editor.saveThermal(thermalPayload, pin: '1234');

      session.sent.clear();
      session.queueOk();
      session.queueOk(thermalBytes());

      expect(await editor.saveThermal(thermalPayload), isA<SaveOk>());
      expect(session.sent.first.op, 0x11, reason: 'straight to CFG_SET');
    });
  });

  group('refusals', () {
    test('a wrong PIN reports itself and writes nothing', () async {
      session.queue(const ControlRefused(ControlStatus.errAuth));

      final outcome = await editor.saveThermal(thermalPayload, pin: '9999');

      expect(outcome, isA<SaveWrongPin>());
      expect(session.sent, hasLength(1), reason: 'AUTH only');
      expect(editor.authenticated, isFalse,
          reason: 'the firmware clears the session on a bad PIN');
    });

    test('armed reports armed and never asks for a PIN', () async {
      // gateRequest reports ErrState before ErrAuth precisely so a client does
      // not prompt for a password to do something refused either way.
      session.queue(const ControlRefused(ControlStatus.errState));

      final outcome = await editor.saveThermal(thermalPayload, pin: '1234');

      expect(outcome, isA<SaveRefusedArmed>());
      expect(outcome, isNot(isA<SaveNeedsPin>()));
    });

    test('ErrBadArg is reported as divergence, not as pilot error', () async {
      session.queueOk(); // AUTH
      session.queue(const ControlRefused(ControlStatus.errBadArg));

      final outcome = await editor.saveThermal(thermalPayload, pin: '1234');

      expect(outcome, isA<SaveRejectedByController>(),
          reason: 'the app accepted a value the firmware did not — the two '
              'validation copies have drifted');
    });

    test('ErrBadOp means the firmware cannot write at all', () async {
      session.queueOk();
      session.queue(const ControlRefused(ControlStatus.errBadOp));
      expect(await editor.saveThermal(thermalPayload, pin: '1234'),
          isA<SaveUnsupported>());
    });

    test('a lost session mid-save asks for the PIN again', () async {
      session.queueOk(); // AUTH
      session.queue(const ControlRefused(ControlStatus.errAuth)); // CFG_SET

      final outcome = await editor.saveThermal(thermalPayload, pin: '1234');

      expect(outcome, isA<SaveNeedsPin>());
      expect(editor.authenticated, isFalse);
    });
  });

  group('retrying', () {
    test('a timed-out AUTH is resent, because AUTH is idempotent', () async {
      session.queue(const ControlTimeout());
      session.queueOk(); // AUTH, second attempt
      session.queueOk(); // CFG_SET
      session.queueOk(thermalBytes());

      expect(await editor.saveThermal(thermalPayload, pin: '1234'),
          isA<SaveOk>());
      expect(session.sent.where((r) => r.op == 0x01), hasLength(2));
    });

    test('a timed-out CFG_SET is resent, because writing twice is the same '
        'state', () async {
      session.queueOk(); // AUTH
      session.queue(const ControlTimeout());
      session.queueOk(); // CFG_SET, second attempt
      session.queueOk(thermalBytes());

      expect(await editor.saveThermal(thermalPayload, pin: '1234'),
          isA<SaveOk>());
      expect(session.sent.where((r) => r.op == 0x11), hasLength(2));
    });

    test('a dropped link is not retried', () async {
      session.queue(const ControlDropped());
      expect(await editor.saveThermal(thermalPayload, pin: '1234'),
          isA<SaveFailed>());
      expect(session.sent, hasLength(1));
    });

    test('giving up after three timeouts reports failure', () async {
      session.queue(const ControlTimeout());
      session.queue(const ControlTimeout());
      session.queue(const ControlTimeout());
      expect(await editor.saveThermal(thermalPayload, pin: '1234'),
          isA<SaveFailed>());
    });
  });

  group('the re-read', () {
    test('a successful write returns what the controller now holds', () async {
      session.queueOk();
      session.queueOk();
      // The controller reports something other than what was sent, which is
      // exactly why the app asks instead of assuming.
      session.queueOk(thermalBytes(motorStartMc: 85000));

      final outcome = await editor.saveThermal(thermalPayload, pin: '1234');

      expect(outcome, isA<SaveOk>());
      expect((outcome as SaveOk).thermal!.motorReductionStartC,
          closeTo(85.0, 1e-9));
    });

    test('a write that lands but whose re-read fails is still a success',
        () async {
      session.queueOk(); // AUTH
      session.queueOk(); // CFG_SET
      session.queue(const ControlTimeout()); // re-read
      session.queue(const ControlTimeout());
      session.queue(const ControlTimeout());

      final outcome = await editor.saveThermal(thermalPayload, pin: '1234');

      expect(outcome, isA<SaveOk>(),
          reason: 'the controller accepted it; only the confirmation is missing');
      expect((outcome as SaveOk).thermal, isNull);
    });
  });

  test('the power group saves through the same path', () async {
    session.queueOk();
    session.queueOk();
    session.queueOk(Uint8List(9));

    const power = PowerConfig(
      capacityMah: 20000,
      minVoltageMv: 42000,
      maxVoltageMv: 58800,
      powerControlEnabled: true,
      voltageDividerRatio: 11.05,
    );

    expect(await editor.savePower(power, pin: '1234'), isA<SaveOk>());
    expect(session.sent[1].payload.first, ConfigGroup.power.id);
  });
}
