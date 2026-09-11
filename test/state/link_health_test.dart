import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/state/link_health.dart';

final t0 = DateTime.utc(2026, 9, 9, 12, 0, 0);
DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

TelemetryFrame frameAt(DateTime t) => TelemetryFrame(
      socCoulomb: 87,
      socVoltage: 91,
      voltage: 50.4,
      powerKw: 1.5,
      throttlePct: 42,
      throttleRaw: 1234,
      powerPct: 100,
      motorTempC: 61,
      motorTempSource: MotorTempSource.can,
      rpm: 4200,
      currentA: 30,
      escTempC: 54,
      armState: ArmState.armed,
      disarmReason: DisarmReason.none,
      bmsMaxTempC: 38,
      cellMinMv: 3712,
      cellMaxMv: 3745,
      receivedAt: t,
    );

void main() {
  test('starts with no frame and no rejections', () {
    final h = LinkHealth();
    expect(h.frameAt(t0), isNull);
    expect(h.isStale(t0), isFalse);
    expect(h.rejectedCount, 0);
  });

  test('a valid frame becomes the current frame', () {
    final h = LinkHealth();
    expect(h.onFrame(frameAt(t0), t0), isTrue);
    expect(h.frameAt(t0)!.socCoulomb, 87);
  });

  test('the frame survives up to the staleness threshold', () {
    final h = LinkHealth()..onFrame(frameAt(t0), t0);
    expect(h.frameAt(at(2)), isNotNull);
    expect(h.isStale(at(2)), isFalse);
  });

  test('past the threshold the frame is withheld, not frozen', () {
    final h = LinkHealth()..onFrame(frameAt(t0), t0);
    expect(h.frameAt(at(4)), isNull);
    expect(h.isStale(at(4)), isTrue);
  });

  test('a fresh frame clears staleness', () {
    final h = LinkHealth()..onFrame(frameAt(t0), t0);
    expect(h.isStale(at(4)), isTrue);
    h.onFrame(frameAt(at(5)), at(5));
    expect(h.isStale(at(5)), isFalse);
    expect(h.frameAt(at(5)), isNotNull);
  });

  test('a rejected frame is counted and does not replace the good frame', () {
    final h = LinkHealth()..onFrame(frameAt(t0), t0);
    expect(h.onFrame(null, at(1)), isFalse);
    expect(h.rejectedCount, 1);
    expect(h.frameAt(at(1))!.socCoulomb, 87);
  });

  test('a rejected frame does not refresh staleness', () {
    final h = LinkHealth()..onFrame(frameAt(t0), t0);
    h.onFrame(null, at(2));
    expect(h.isStale(at(4)), isTrue);
  });

  test('reset clears the frame but keeps the rejection tally', () {
    final h = LinkHealth()
      ..onFrame(frameAt(t0), t0)
      ..onFrame(null, t0);
    h.reset();
    expect(h.frameAt(t0), isNull);
    expect(h.isStale(t0), isFalse);
    expect(h.rejectedCount, 1);
  });

  test('a rejected frame does not refresh the clock', () {
    final t0 = DateTime.utc(2026, 9, 11, 12);
    final health = LinkHealth();
    health.onFrame(frameAt(t0), t0);

    // Two seconds of garbage must not keep the panel alive: a stream of
    // rubbish has to age out exactly like silence.
    final t2 = t0.add(const Duration(seconds: 2));
    health.onFrame(null, t2);
    expect(health.rejectedCount, 1);

    final t4 = t0.add(const Duration(seconds: 4));
    expect(health.frameAt(t4), isNull);
    expect(health.isStale(t4), isTrue);
  });
}
