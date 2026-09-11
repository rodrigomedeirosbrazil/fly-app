import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/bms_scan.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/state/bms_scan_controller.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/state/control_session.dart';

import 'fake_session.dart';

Future<void> pumpUntil(bool Function() done, {int maxTicks = 200}) async {
  for (var i = 0; i < maxTicks && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('a scan runs from scanning to complete and then stops polling',
      () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(editor,
        pollInterval: const Duration(milliseconds: 10));

    session.queueOk();                       // AUTH
    session.queueOk();                       // BMS_SCAN_START
    session.queueOk([1, 0]);                 // scanning
    session.queueOk([2, 1, 1, 2, 3, 4, 5, 6, (-50) & 0xFF, 1]);  // complete

    await c.start(pin: '1234');
    await pumpUntil(() => c.status == BmsScanStatus.complete);

    expect(c.results, hasLength(1));
    expect(c.isPolling, isFalse);
  });

  test('ErrBusy is reported as busy, not as a failure', () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(editor,
        pollInterval: const Duration(milliseconds: 10));

    session.queueOk();                                       // AUTH
    session.queue(const ControlRefused(ControlStatus.errBusy));

    expect(await c.start(pin: '1234'), isA<SaveBusy>());
    expect(c.refusal, isA<SaveBusy>());
    expect(c.isPolling, isFalse);
  });

  test('a poll that does not answer stops the scan and says so', () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(editor,
        pollInterval: const Duration(milliseconds: 10));

    session.queueOk();                       // AUTH
    session.queueOk();                       // BMS_SCAN_START
    session.queueOk([1, 0]);                 // scanning, first poll
    // No response for the second poll, so FakeSession will return ControlTimeout

    await c.start(pin: '1234');
    await pumpUntil(() => c.status == BmsScanStatus.error);

    expect(c.isPolling, isFalse);
  });

  test('stop() cancels the timer', () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(editor,
        pollInterval: const Duration(milliseconds: 10));

    session.queueOk();                       // AUTH
    session.queueOk();                       // BMS_SCAN_START
    session.queueOk([1, 0]);                 // scanning

    await c.start(pin: '1234');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    c.stop();

    expect(c.isPolling, isFalse);
  });

  test('an armed controller refuses, and no PIN is asked for', () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(editor,
        pollInterval: const Duration(milliseconds: 10));

    session.queue(const ControlRefused(ControlStatus.errState));

    // Start with a PIN — armed rejection should come back before even trying the scan
    final outcome = await c.start(pin: '1234');

    expect(outcome, isA<SaveRefusedArmed>());
    expect(c.refusal, isA<SaveRefusedArmed>());
    expect(c.isPolling, isFalse);
  });
}
