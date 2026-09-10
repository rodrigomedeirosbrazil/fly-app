import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/state/telemetry_repository.dart';

const sample =
    r'$XCTOD,87,91,50.400,1.5,42,1234,100,61,can,4200,30,54,ARMED,38,3712,3745';

/// Stands in for the radio. Overriding the two streams is enough: everything
/// above [FlyControllerLink] is testable precisely because that class is the
/// only thing that touches hardware.
class FakeLink extends FlyControllerLink {
  final _status = StreamController<LinkStatus>.broadcast();
  final _payloads = StreamController<List<int>>.broadcast();

  @override
  Stream<LinkStatus> get status => _status.stream;

  @override
  Stream<List<int>> get payloads => _payloads.stream;

  /// Set before calling start() to simulate the pilot refusing the Android
  /// runtime permission.
  bool deniesPermissions = false;

  @override
  Future<bool> ensurePermissions() async => !deniesPermissions;

  @override
  Future<void> connect() async => _status.add(LinkStatus.connected);

  @override
  Future<void> disconnect() async => _status.add(LinkStatus.idle);

  @override
  Future<void> dispose() async {
    await _status.close();
    await _payloads.close();
  }

  void emit(LinkStatus s) => _status.add(s);

  void feed(String line) => _payloads.add('$line\r\n'.codeUnits);
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

  test('a refused permission is reported, not swallowed', () async {
    link.deniesPermissions = true;

    await repo.start();

    expect(repo.status, LinkStatus.unauthorized);
  });

  test('granting it afterwards clears the refusal', () async {
    link.deniesPermissions = true;
    await repo.start();
    expect(repo.status, LinkStatus.unauthorized);

    link.deniesPermissions = false;
    await repo.start();
    await pumpEventQueue();

    expect(repo.status, LinkStatus.connected);
  });
}
