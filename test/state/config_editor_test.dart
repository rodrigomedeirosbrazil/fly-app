import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/bms_scan.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/protocol/mac_address.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/state/control_session.dart';

import 'fake_session.dart';

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

  group('the action opcodes', () {
    test('a scan start needs the PIN, like any other write', () async {
      expect(await editor.startBmsScan(), isA<SaveNeedsPin>());
      expect(session.sent, isEmpty);
    });

    test('a scan start while armed never asks for a PIN', () async {
      session.queue(const ControlRefused(ControlStatus.errState));

      expect(await editor.startBmsScan(pin: '1234'), isA<SaveRefusedArmed>());
      // AUTH went out and was refused as armed; the scan itself never did.
      expect(session.sent, hasLength(1));
    });

    test('ErrBusy means a scan is already running', () async {
      session.queueOk();                                       // AUTH
      session.queue(const ControlRefused(ControlStatus.errBusy));

      expect(await editor.startBmsScan(pin: '1234'), isA<SaveBusy>());
      expect(session.sent.last.op, 0x21);
    });

    test('reading the scan status needs no PIN and no session', () async {
      session.queueOk([2, 0]);

      final state = await editor.readBmsScan();

      expect(state, isNotNull);
      expect(state!.status, BmsScanStatus.complete);
      expect(session.sent.single.op, 0x22);
      expect(editor.authenticated, isFalse);
    });

    test('a scan status that does not answer is null, not an empty scan',
        () async {
      // Nothing queued, so FakeSession answers ControlTimeout.
      expect(await editor.readBmsScan(), isNull);
    });

    test('the status read is not retried', () async {
      await editor.readBmsScan();
      expect(session.sent, hasLength(1));
    });

    test('pairing maps refusals like every other write', () async {
      session.queueOk();                                        // AUTH
      session.queue(const ControlRefused(ControlStatus.errBadOp));

      expect(await editor.pairRemote(pin: '1234'), isA<SaveUnsupported>());
      expect(session.sent.last.op, 0x24);
    });

    test('forgetting sends REMOTE_FORGET', () async {
      session.queueOk();                                        // AUTH
      session.queueOk();

      expect(await editor.forgetRemote(pin: '1234'), isA<SaveOk>());
      expect(session.sent.last.op, 0x25);
    });

    test('a buzzer preview past 100 is refused before it is sent', () async {
      expect(await editor.previewBuzzer(101, pin: '1234'),
          isA<SaveRejectedByController>());
      expect(session.sent, isEmpty);
    });

    test('a buzzer preview is never retried, because it makes a sound',
        () async {
      session.queueOk();                        // AUTH
      // Nothing queued for the preview, so it times out.
      expect(await editor.previewBuzzer(70, pin: '1234'), isA<SaveFailed>());
      expect(session.sent.where((s) => s.op == 0x26), hasLength(1));
    });

    test('the BMS group saves and re-reads through the same path', () async {
      session.queueOk();                                        // AUTH
      session.queueOk();                                        // CFG_SET
      session.queueOk([1, 1, 2, 3, 4, 5, 6]);                   // CFG_GET

      final outcome = await editor.saveBms(
          const BmsConfig(bmsType: 1, bmsMac: [1, 2, 3, 4, 5, 6]),
          pin: '1234') as SaveOk;

      expect(outcome.bms!.bmsType, 1);
      expect(session.sent[1].payload.first, ConfigGroup.bms.id);
    });

    test('the System group saves through the same path', () async {
      session.queueOk();                                        // AUTH
      session.queueOk();                                        // CFG_SET
      session.queueOk([70, 1, 0, 0, 0, 0, 0, 0]);               // CFG_GET

      final outcome = await editor.saveSystem(
          const SystemConfig(
              buzzerVolume: 70, throttleSource: 1, remoteMac: kUnsetMac),
          pin: '1234') as SaveOk;

      expect(outcome.system!.buzzerVolume, 70);
    });

    test('readSystemConfig is a plain open read', () async {
      session.queueOk([70, 1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);

      final config = await editor.readSystemConfig();

      expect(config!.remoteMac, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
      expect(session.sent.single.op, 0x10);
    });
  });
}
