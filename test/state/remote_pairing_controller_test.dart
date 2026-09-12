import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/state/control_session.dart';
import 'package:fly_app/state/remote_pairing_controller.dart';

import 'fake_session.dart';

Future<void> pumpUntil(bool Function() done, {int maxTicks = 200}) async {
  for (var i = 0; i < maxTicks && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('resolves when remoteMac turns non-zero', () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = RemotePairingController(editor,
        pollInterval: const Duration(milliseconds: 10),
        deadline: const Duration(seconds: 5));

    session.queueOk();                                        // AUTH
    session.queueOk();                                        // REMOTE_PAIR
    session.queueOk([70, 1, 0, 0, 0, 0, 0, 0]);              // unset MAC
    session.queueOk([70, 1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);  // paired

    await c.start(pin: '1234');
    await pumpUntil(() => c.state == PairingState.paired);

    expect(c.pairedMac, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
    expect(c.stillListening, isFalse);
  });

  test('gives up after the deadline, and says the controller is still '
      'listening', () async {
    // The firmware has no pairing timeout and no cancel opcode. A controller
    // left in pairing mode pairs the next remote powered on nearby, and the
    // pilot has to know that.
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = RemotePairingController(editor,
        pollInterval: const Duration(milliseconds: 30),
        deadline: const Duration(milliseconds: 100));

    session.queueOk();                                        // AUTH
    session.queueOk();                                        // REMOTE_PAIR
    session.queueOk([70, 1, 0, 0, 0, 0, 0, 0]);              // unset, poll 1
    session.queueOk([70, 1, 0, 0, 0, 0, 0, 0]);              // unset, poll 2
    session.queueOk([70, 1, 0, 0, 0, 0, 0, 0]);              // unset, poll 3
    session.queueOk([70, 1, 0, 0, 0, 0, 0, 0]);              // unset, poll 4

    await c.start(pin: '1234');
    await pumpUntil(() => c.state == PairingState.gaveUp, maxTicks: 300);

    expect(c.state, PairingState.gaveUp);
    expect(c.stillListening, isTrue);
  });

  test('cancel() stops polling but still reports the controller listening',
      () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = RemotePairingController(editor,
        pollInterval: const Duration(milliseconds: 10),
        deadline: const Duration(seconds: 5));

    session.queueOk();                                        // AUTH
    session.queueOk();                                        // REMOTE_PAIR
    session.queueOk([70, 1, 0, 0, 0, 0, 0, 0]);              // unset MAC

    await c.start(pin: '1234');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    c.cancel();

    expect(c.state, PairingState.idle);
    expect(c.stillListening, isTrue);
  });

  test('a refusal while armed never asks for a PIN', () async {
    final session = FakeSession();
    final editor = ConfigEditor(session);
    final c = RemotePairingController(editor,
        pollInterval: const Duration(milliseconds: 10),
        deadline: const Duration(seconds: 5));

    session.queue(const ControlRefused(ControlStatus.errState));

    // Start with a PIN — armed rejection should come back before even trying to pair
    final outcome = await c.start(pin: '1234');

    expect(outcome, isA<SaveRefusedArmed>());
    expect(c.refusal, isA<SaveRefusedArmed>());
    expect(c.state, PairingState.refused);
  });

  test('a read that never answers still gives up at the deadline', () async {
    // The System read is a plain CFG_GET, and a quiet link answers none of
    // them. Treating an unanswered poll as "keep waiting" without counting it
    // left the pilot on a spinner with no end -- exactly when something is
    // already wrong.
    final session = FakeSession();  // nothing queued: every read times out
    final editor = ConfigEditor(session);
    session.queueOk();              // AUTH
    session.queueOk();              // REMOTE_PAIR
    final c = RemotePairingController(
      editor,
      pollInterval: const Duration(milliseconds: 5),
      deadline: const Duration(milliseconds: 25),
    );

    await c.start(pin: '1234');
    for (var i = 0; i < 40 && c.state == PairingState.waiting; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(c.state, PairingState.gaveUp);
    expect(c.stillListening, isTrue);
    c.dispose();
  });
}
