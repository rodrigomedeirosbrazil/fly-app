import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/state/telemetry_repository.dart';
import 'package:fly_app/state/telemetry_source_policy.dart';

const sample =
    r'$XCTOD,87,91,50.400,1.5,42,1234,100,61,can,4200,30,54,ARMED,38,3712,3745';

/// A minimal valid binary frame: struct version 1, armed, all three signals
/// Valid, 87 % coulomb SoC, a 12:34 flight clock.
Uint8List binarySample({int ver = 1, int sessionSec = 754}) {
  final d = ByteData(56);
  d.setUint8(0, ver);
  d.setUint8(1, 0x01); // armed
  d.setUint8(5, 0x3F); // motor, esc, battery all Valid
  d.setUint8(7, 87); // socCc
  d.setUint8(10, 100); // powerPct
  d.setUint32(36, sessionSec, Endian.little);
  return d.buffer.asUint8List();
}

/// Stands in for the radio. Overriding the two streams is enough: everything
/// above [FlyControllerLink] is testable precisely because that class is the
/// only thing that touches hardware.
class FakeLink extends FlyControllerLink {
  final _status = StreamController<LinkStatus>.broadcast();
  final _payloads = StreamController<TelemetryPayload>.broadcast();
  final _responses = StreamController<List<int>>.broadcast();
  final commands = <List<int>>[];

  @override
  Stream<LinkStatus> get status => _status.stream;

  @override
  Stream<TelemetryPayload> get payloads => _payloads.stream;

  @override
  Stream<List<int>> get responses => _responses.stream;

  @override
  bool get canSendCommands => true;

  /// Set to fail every write, standing in for a controller with no CMD.
  bool rejectCommands = false;

  @override
  Future<void> sendCommand(List<int> bytes) async {
    if (rejectCommands) throw StateError('no CMD characteristic');
    commands.add(bytes);
  }

  /// Replies to the request at [index] with a full Thermal group.
  void replyThermal(int index, {int status = 0}) {
    final req = commands[index];
    final d = ByteData(17);
    d.setInt32(0, 80000, Endian.little);
    d.setInt32(4, 100000, Endian.little);
    d.setInt32(8, 70000, Endian.little);
    d.setInt32(12, 95000, Endian.little);
    final payload = status == 0 ? d.buffer.asUint8List() : Uint8List(0);
    _responses.add([req[0], req[1], status, payload.length, ...payload]);
  }

  /// Replies with a status and no payload.
  void replyStatus(int index, int status) {
    final req = commands[index];
    _responses.add([req[0], req[1], status, 0]);
  }

  /// Set before calling start() to simulate a precondition the pilot has to
  /// fix: a refused permission, Bluetooth off, or location off.
  LinkStatus? blocking;

  @override
  Future<LinkStatus?> blockingCondition() async => blocking;

  int connectCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls++;
    _status.add(LinkStatus.connected);
  }

  @override
  Future<void> disconnect() async => _status.add(LinkStatus.idle);

  @override
  Future<void> dispose() async {
    await _status.close();
    await _payloads.close();
    await _responses.close();
  }

  int fallbackCalls = 0;

  @override
  Future<void> fallBackToXctod() async => fallbackCalls++;

  void emit(LinkStatus s) => _status.add(s);

  void feed(String line) => _payloads.add(
        TelemetryPayload(TelemetrySource.xctod, '$line\r\n'.codeUnits),
      );

  void feedBinary(Uint8List bytes) =>
      _payloads.add(TelemetryPayload(TelemetrySource.control, bytes));
}

void main() {
  late DateTime now;
  late FakeLink link;
  late TelemetryRepository repo;

  setUp(() {
    now = DateTime.utc(2026, 9, 10, 12);
    link = FakeLink();
    repo = TelemetryRepository(link: link, clock: () => now);
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

      expect(link.commands, hasLength(1));
      expect(link.commands.single[0], 0x10, reason: 'CFG_GET');
      expect(link.commands.single[3], ConfigGroup.thermal.id);

      link.replyThermal(0);
      await pumpEventQueue();

      expect(repo.thermalConfig, isNotNull);
      expect(repo.thermalConfig!.motorBandStartC, closeTo(80.0, 1e-9));
      expect(repo.thermalConfig!.motorBandEndC, closeTo(100.0, 1e-9));

      // A second frame must not re-ask.
      link.feedBinary(binarySample());
      await pumpEventQueue();
      expect(link.commands, hasLength(1));
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
      expect(repo.thermalConfig, isNotNull);

      link.emit(LinkStatus.disconnected);
      await pumpEventQueue();
      expect(repo.thermalConfig, isNull,
          reason: 'thresholds are per connection and never cached');

      link.emit(LinkStatus.connected);
      link.feedBinary(binarySample());
      await pumpEventQueue();
      expect(link.commands, hasLength(2));
    });
  });
}
