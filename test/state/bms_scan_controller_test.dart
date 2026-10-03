import 'dart:async';

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

  List<int> detailBytes(List<int> mac, String name) =>
      [...mac, 0xC3, 3, name.length, ...name.codeUnits, 0];

  test('a completed scan fetches each result\'s name', () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(editor,
        pollInterval: const Duration(milliseconds: 10));

    session.queueOk(); // AUTH
    session.queueOk(); // BMS_SCAN_START
    session.queueOk([2, 1, 1, 2, 3, 4, 5, 6, (-50) & 0xFF, 3]); // complete
    session.queueOk(detailBytes([1, 2, 3, 4, 5, 6], 'JK-B2A24S'));

    await c.start(pin: '1234');
    await pumpUntil(
        () => c.results.isNotEmpty && c.detailFor(c.results.first) != null);

    expect(c.detailFor(c.results.first)!.name, 'JK-B2A24S');
    expect(session.sent.last.op, 0x2B);
    expect(session.sent.last.payload, [0]);
  });

  test('old firmware is asked once and then left alone', () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(editor,
        pollInterval: const Duration(milliseconds: 10));

    session.queueOk(); // AUTH
    session.queueOk(); // BMS_SCAN_START
    session.queueOk([2, 2,
      1, 2, 3, 4, 5, 6, (-50) & 0xFF, 0,
      7, 8, 9, 10, 11, 12, (-70) & 0xFF, 0]); // complete, two results
    session.queue(const ControlRefused(ControlStatus.errBadOp));

    await c.start(pin: '1234');
    await pumpUntil(() => c.status == BmsScanStatus.complete);
    await pumpUntil(() => false, maxTicks: 10);

    expect(session.sent.where((r) => r.op == 0x2B), hasLength(1));
    expect(c.detailFor(c.results.first), isNull);
  });

  test('a new scan stops an older detail fetch from writing', () async {
    // The fetch of scan 1 is still waiting on its reply when scan 2 starts.
    // Its answer describes a device from a scan that no longer exists, and
    // start() has just cleared exactly that.
    final session = _GatedDetailSession();
    final editor = ConfigEditor(session);
    final c = BmsScanController(editor,
        pollInterval: const Duration(milliseconds: 10));

    session.queueOk(); // AUTH
    session.queueOk(); // BMS_SCAN_START
    session.queueOk([2, 1, 1, 2, 3, 4, 5, 6, (-50) & 0xFF, 3]); // complete
    await c.start(pin: '1234');
    await pumpUntil(() => session.gate != null);
    final old = c.results.first;

    session.queueOk(); // second BMS_SCAN_START
    await c.start();
    session.gate!.complete(ControlOk(detailBytes([1, 2, 3, 4, 5, 6], 'OLD')));
    await pumpUntil(() => false, maxTicks: 6);

    expect(c.detailFor(old), isNull);
    expect(session.detailRequests, 1, reason: 'the old loop did not go on');
    c.dispose();
  });
}

/// Holds the first detail request until the test releases it.
class _GatedDetailSession extends FakeSession {
  Completer<ControlResult>? gate;
  int detailRequests = 0;

  @override
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) {
    if (op == 0x2B) {
      detailRequests++;
      sent.add((op: op, payload: payload));
      return (gate ??= Completer<ControlResult>()).future;
    }
    return super.request(op: op, payload: payload);
  }
}
