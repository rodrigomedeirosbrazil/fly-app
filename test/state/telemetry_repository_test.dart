import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/audio/tone_player.dart';
import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/state/buzzer_mirror.dart';
import 'package:fly_app/state/telemetry_repository.dart';

import 'fake_link.dart';

const sample =
    r'$XCTOD,87,91,50.400,1.5,42,1234,100,61,can,4200,30,54,ARMED,38,3712,3745';

class FakePlayer implements TonePlayer {
  final calls = <String>[];

  @override
  Future<void> playPattern({
    required int frequency,
    required int onMs,
    required int offMs,
    required int reps,
  }) async =>
      calls.add('play $frequency/$onMs/$offMs x$reps');

  @override
  Future<void> startLoop({
    required int frequency,
    required int onMs,
    required int offMs,
  }) async =>
      calls.add('loop $frequency/$onMs/$offMs');

  @override
  Future<void> stopLoop() async => calls.add('stop');

  @override
  Future<void> silence() async => calls.add('silence');

  @override
  Future<void> dispose() async {}
}

void main() {
  late DateTime now;
  late FakeLink link;
  late TelemetryRepository repo;

  setUp(() {
    now = DateTime.utc(2026, 9, 10, 12);
    link = FakeLink();
    // Inject a fake player so the test doesn't try to initialize audio
    final fakePlayer = FakePlayer();
    final mirror = BuzzerMirror(fakePlayer);
    repo = TelemetryRepository(link: link, clock: () => now, mirror: mirror);
  });

  tearDown(() => repo.dispose());

  Future<void> receiveOneFrame() async {
    link.emit(LinkStatus.connected);
    link.feed(sample);
    await pumpEventQueue();
  }

  test('a dropped link keeps the last frame, so it reads as stale', () async {
    await receiveOneFrame();
    expect(repo.frame, isNotNull);

    link.emit(LinkStatus.disconnected);
    await pumpEventQueue();
    now = now.add(const Duration(seconds: 5));

    // Withheld, because it is old.
    expect(repo.frame, isNull);
    // But remembered, because the app must not fall back to the connection
    // screen while the pilot is in the air. Do not "fix a leak" by putting
    // _health.reset() back on the disconnected branch.
    expect(repo.isStale, isTrue);
  });

  test('an explicit stop forgets the frame', () async {
    await receiveOneFrame();

    await repo.stop();
    await pumpEventQueue();

    expect(repo.frame, isNull);
    expect(repo.isStale, isFalse, reason: 'stop() means never connected');
  });

  test('nothing received at all is not stale', () async {
    link.emit(LinkStatus.scanning);
    await pumpEventQueue();

    expect(repo.frame, isNull);
    expect(repo.isStale, isFalse);
  });

  test('a blocked precondition is reported, not swallowed', () async {
    link.blocking = LinkStatus.unauthorized;

    await repo.start();

    expect(repo.status, LinkStatus.unauthorized);
    // A silent no-op button is indistinguishable from a broken one, and the
    // radio must not be started behind a refusal either.
    expect(link.connectCalls, 0);
  });

  test('clearing it afterwards lets the connection through', () async {
    link.blocking = LinkStatus.unauthorized;
    await repo.start();
    expect(repo.status, LinkStatus.unauthorized);

    link.blocking = null;
    await repo.start();
    await pumpEventQueue();

    expect(repo.status, LinkStatus.connected);
  });

  for (final blocked in const [
    LinkStatus.unauthorized,
    LinkStatus.bluetoothOff,
    LinkStatus.locationOff,
  ]) {
    test('$blocked does not forget the last frame', () async {
      await receiveOneFrame();
      expect(repo.frame, isNotNull);

      link.emit(blocked);
      await pumpEventQueue();

      // Only an explicit stop() forgets the frame. Otherwise Bluetooth
      // switched off mid-flight would satisfy FlyApp's
      // `frame == null && !isStale` and swap the instrument panel for the
      // logo — the worst possible moment to change what is on screen.
      expect(repo.frame, isNotNull);
      expect(repo.status, blocked);
    });
  }

  test('a binary payload decodes through the control codec', () async {
    link.emit(LinkStatus.connected);
    link.feedBinary(binarySample());
    await pumpEventQueue();

    expect(repo.frame, isNotNull);
    expect(repo.frame!.socCoulomb, 87);
    expect(repo.frame!.sessionSec, const Duration(seconds: 754));
  });

  test('a CSV payload still decodes through the sentence parser', () async {
    await receiveOneFrame();

    expect(repo.frame, isNotNull);
    expect(repo.frame!.socCoulomb, 87);
    expect(repo.frame!.sessionSec, isNull,
        reason: 'the sentence cannot carry a flight clock');
  });

  test('an undecodable first binary frame falls back to the sentence',
      () async {
    link.emit(LinkStatus.connected);
    link.feedBinary(binarySample(ver: 2));
    await pumpEventQueue();

    expect(link.fallbackCalls, 1);
    expect(repo.frame, isNull);
    expect(repo.rejectedFrames, 1);
  });

  test('a bad frame after one has rendered does not change the source',
      () async {
    link.emit(LinkStatus.connected);
    link.feedBinary(binarySample());
    await pumpEventQueue();
    expect(repo.frame, isNotNull);

    link.feedBinary(binarySample(ver: 2));
    await pumpEventQueue();

    expect(link.fallbackCalls, 0,
        reason: 'a live panel must not swap which readings exist');
    expect(repo.rejectedFrames, 1);
  });

  group('thermal config', () {
    test('is requested once, after the first binary frame', () async {
      link.emit(LinkStatus.connected);
      expect(link.commands, isEmpty,
          reason: 'connecting alone proves nothing about the service');

      link.feedBinary(binarySample());
      await pumpEventQueue();

      expect(link.commands, hasLength(1),
          reason: 'thermal is requested first');
      expect(link.commands[0][0], 0x10, reason: 'CFG_GET');
      expect(link.commands[0][3], ConfigGroup.thermal.id);

      link.replyThermal(0);
      await pumpEventQueue();

      expect(link.commands, hasLength(2),
          reason: 'power is requested after thermal succeeds');
      expect(link.commands[1][3], ConfigGroup.power.id);

      expect(repo.thermalConfig, isNotNull);
      expect(repo.thermalConfig!.motorBandStartC, closeTo(80.0, 1e-9));
      expect(repo.thermalConfig!.motorBandEndC, closeTo(100.0, 1e-9));

      // A second frame must not re-ask.
      link.feedBinary(binarySample());
      await pumpEventQueue();
      expect(link.commands, hasLength(2));
    });

    test('is never requested on the sentence path', () async {
      await receiveOneFrame();
      expect(repo.frame, isNotNull);
      expect(link.commands, isEmpty,
          reason: 'firmware without the service has no CMD to write to');
      expect(repo.thermalConfig, isNull);
    });

    test('a refusal stops without retrying', () async {
      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();

      link.replyStatus(0, 2); // ErrBadOp — old firmware
      await pumpEventQueue();

      // CFG_GET is one opcode with the group as a payload byte, so ErrBadOp
      // is about the request itself: the Power group would be refused
      // identically and is not asked for.
      expect(link.commands, hasLength(1));
      expect(repo.thermalConfig, isNull,
          reason: 'no band, and nothing on screen says so');
    });

    test('a failed write does not retry either', () async {
      link.rejectCommands = true;
      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();

      expect(repo.thermalConfig, isNull);
    });

    test('a reconnection asks again', () async {
      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();
      link.replyThermal(0);
      await pumpEventQueue();
      expect(link.commands, hasLength(2),
          reason: 'thermal and power sent after first frame');
      expect(repo.thermalConfig, isNotNull);

      link.emit(LinkStatus.disconnected);
      await pumpEventQueue();
      expect(repo.thermalConfig, isNull,
          reason: 'thresholds are per connection and never cached');

      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();
      expect(link.commands, hasLength(3),
          reason: 'thermal sent again after reconnect');
    });
  });

  group('all four groups', () {
    test('all four groups are fetched on the first binary frame', () async {
      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();

      expect(link.commands, hasLength(1),
          reason: 'thermal is requested first');
      expect(link.commands[0][3], ConfigGroup.thermal.id);
      link.replyThermal(0);
      await pumpEventQueue();

      expect(link.commands, hasLength(2),
          reason: 'power is requested after thermal succeeds');
      expect(link.commands[1][3], ConfigGroup.power.id);
      link.replyPower(1);
      await pumpEventQueue();

      expect(link.commands, hasLength(3),
          reason: 'bms is requested after power succeeds');
      expect(link.commands[2][3], ConfigGroup.bms.id);
      link.replyStatus(2, 0); // Reply OK with no payload — BMS will decode as null
      await pumpEventQueue();

      expect(link.commands, hasLength(4),
          reason: 'system is requested after bms succeeds');
      expect(link.commands[3][3], ConfigGroup.system.id);
      link.replyStatus(3, 0); // Reply OK with no payload — System will decode as null
      await pumpEventQueue();

      expect(repo.thermalConfig, isNotNull,
          reason: 'thermal was fetched and decoded');
      expect(repo.thermalConfig!.motorBandStartC, closeTo(80.0, 1e-9));
      expect(repo.powerConfig, isNotNull,
          reason: 'power was fetched and decoded');
      expect(repo.powerConfig!.capacityMah, 18000);
      // BMS and System configs are null because replyStatus sends empty payload,
      // but the requests were still sent, which is what this test verifies
    });

    test('ErrBadOp on the first group stops the whole sequence', () async {
      // A controller without CFG_GET refuses all four identically. Finding that
      // out once is enough, and asking three more times costs radio time on a
      // link that is already carrying telemetry.
      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();

      link.replyStatus(0, 2); // ErrBadOp
      await pumpEventQueue();

      expect(link.commands, hasLength(1),
          reason: 'only thermal was requested; power, bms and system were not');
      expect(repo.thermalConfig, isNull);
      expect(repo.powerConfig, isNull);
      expect(repo.bmsConfig, isNull);
      expect(repo.systemConfig, isNull);
    });
  });

  group('the editor is per connection', () {
    test('a disconnect drops it, because the PIN does not survive one',
        () async {
      final link = FakeLink();
      final fakePlayer = FakePlayer();
      final mirror = BuzzerMirror(fakePlayer);
      final repo = TelemetryRepository(
        link: link,
        clock: DateTime.now,
        mirror: mirror,
      );
      addTearDown(repo.dispose);

      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();
      expect(repo.editor, isNotNull);

      // The firmware clears authenticated_ in onCentralDisconnected(), so
      // holding an editor across a reconnect would have the app believing in
      // a session the controller has already forgotten.
      link.emit(LinkStatus.disconnected);
      await pumpEventQueue();

      expect(repo.editor, isNull);
    });
  });

  group('buzzer mirror', () {
    test('an EVT_BEEP reaches the mirror', () async {
      final player = FakePlayer();
      final mirror = BuzzerMirror(player);
      link = FakeLink();
      repo = TelemetryRepository(
        link: link,
        clock: () => now,
        mirror: mirror,
      );

      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();

      // Build a 13-byte beep payload
      final d = ByteData(13);
      d.setUint32(0, 7, Endian.little); // seq
      d.setUint16(4, 2000, Endian.little); // frequency
      d.setUint16(6, 120, Endian.little); // onMs
      d.setUint16(8, 80, Endian.little); // offMs
      d.setUint8(10, 3); // reps
      d.setUint8(11, 0); // layer: event
      d.setUint8(12, 1); // active

      // Push an RSP with op 0x80 (EVT_BEEP), seq 0 (unsolicited), and the payload
      link.pushResponse([0x80, 0, 0, 13, ...d.buffer.asUint8List()]);
      await pumpEventQueue();

      expect(player.calls, isNotEmpty);
      expect(player.calls.first, contains('2000'));
    });

    test('an unsolicited event this build does not know is ignored', () async {
      final player = FakePlayer();
      final mirror = BuzzerMirror(player);
      link = FakeLink();
      repo = TelemetryRepository(
        link: link,
        clock: () => now,
        mirror: mirror,
      );

      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();

      // An UNSOLICITED event (seq 0) under an opcode this build does not
      // know, carrying a full 13-byte payload.
      //
      // Both details matter. A seq other than 0 never reaches _onEvent at all
      // -- ControlSession routes it to the pending request instead -- and a
      // short payload is rejected by BeepEvent.decode on length alone. Get
      // either wrong and the test passes with the opcode check deleted, which
      // is what the first version of it did.
      final d = ByteData(13);
      d.setUint32(0, 1, Endian.little);
      d.setUint16(4, 2000, Endian.little);
      d.setUint16(6, 100, Endian.little);
      d.setUint16(8, 50, Endian.little);
      d.setUint8(10, 2);
      d.setUint8(11, 0);
      d.setUint8(12, 1);
      link.pushResponse([0x10, 0, 0, 13, ...d.buffer.asUint8List()]);
      await pumpEventQueue();

      expect(player.calls, isEmpty,
          reason: 'only op 0x80 is a beep, whatever the payload decodes to');
    });
  });
}
