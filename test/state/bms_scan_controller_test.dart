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

  // What used to be here asserted that ONE unanswered poll ends the scan.
  // That was my specification and it was wrong on the aircraft: the
  // controller scans with the same radio that carries this link, so silence
  // during those 5 s is the normal case. The two cases below replace it --
  // silence is tolerated, and only the deadline ends the wait.

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

  test('a missed poll is not a failed scan', () async {
    // THE REGRESSION THIS COVERS.
    //
    // The controller runs its 5 s BLE scan on the same radio that carries
    // this link, and stops advertising for the whole of it, so polls landing
    // inside the scan are the ones most likely to go unanswered. Ending on
    // the first silence made "Buscar BMS" look like it did nothing at all.
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(
      editor,
      pollInterval: const Duration(milliseconds: 5),
      deadline: const Duration(seconds: 5),
    );
    addTearDown(c.dispose);

    session.queueOk();              // AUTH
    session.queueOk();              // BMS_SCAN_START
    // Nothing queued for the next polls: they time out, as a busy controller
    // does. Then the scan answers.
    await c.start(pin: '1234');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(c.status, BmsScanStatus.scanning,
        reason: 'silence during the scan must not end it');

    session.queueOk([2, 1, 1, 2, 3, 4, 5, 6, (-50) & 0xFF, 1]);
    for (var i = 0; i < 20 && c.status == BmsScanStatus.scanning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(c.status, BmsScanStatus.complete);
    expect(c.results, hasLength(1));
  });

  test('a scan that never answers gives up at the deadline', () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(
      editor,
      pollInterval: const Duration(milliseconds: 5),
      deadline: const Duration(milliseconds: 25),
    );
    addTearDown(c.dispose);

    session.queueOk();              // AUTH
    session.queueOk();              // BMS_SCAN_START
    await c.start(pin: '1234');

    for (var i = 0; i < 40 && c.status == BmsScanStatus.scanning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(c.status, BmsScanStatus.error);
    expect(c.isPolling, isFalse);
  });
}
