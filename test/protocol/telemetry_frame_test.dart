import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';

TelemetryFrame frame({
  ArmState armState = ArmState.disarmed,
  DisarmReason disarmReason = DisarmReason.none,
  String? rawDisarmCode,
  int powerPct = 100,
}) =>
    TelemetryFrame(
      socCoulomb: 87,
      socVoltage: 91,
      voltage: 50.4,
      powerKw: 1.5,
      throttlePct: 42,
      throttleRaw: 1234,
      powerPct: powerPct,
      motorTempC: 61,
      motorTempSource: MotorTempSource.can,
      rpm: 4200,
      currentA: 30,
      escTempC: 54,
      armState: armState,
      disarmReason: disarmReason,
      rawDisarmCode: rawDisarmCode,
      bmsMaxTempC: 38,
      cellMinMv: 3712,
      cellMaxMv: 3745,
      receivedAt: DateTime.utc(2026, 9, 11),
    );

void main() {
  group('disarmCode', () {
    test('is null while armed, whatever the reason says', () {
      final f = frame(
        armState: ArmState.armed,
        disarmReason: DisarmReason.motorTempLost,
      );
      expect(f.disarmCode, isNull);
    });

    test('a manual disarm reports no code, exactly as the sentence did', () {
      expect(frame(disarmReason: DisarmReason.manual).disarmCode, isNull);
      expect(frame(disarmReason: DisarmReason.none).disarmCode, isNull);
    });

    test('a fault reports the firmware short code', () {
      expect(
        frame(disarmReason: DisarmReason.motorTempSourceChanged).disarmCode,
        'MOT SRC',
      );
      expect(
        frame(disarmReason: DisarmReason.batteryVoltageLost).disarmCode,
        'BATT ERR',
      );
    });

    test('an unrecognised reason falls back to the raw text it came with', () {
      final f = frame(
        disarmReason: DisarmReason.unknown,
        rawDisarmCode: 'WAT ERR',
      );
      expect(f.disarmCode, 'WAT ERR');
    });
  });

  test('isLimited follows powerPct, not the cause set', () {
    expect(frame(powerPct: 100).isLimited, isFalse);
    expect(frame(powerPct: 80).isLimited, isTrue);
  });

  test('everything the binary source alone provides defaults to null', () {
    final f = frame();
    expect(f.sessionSec, isNull);
    expect(f.limitCauses, isNull);
    expect(f.motorTempState, isNull);
    expect(f.hourMeterSec, isNull);
    expect(f.cellDeltaMv, isNull);
  });
}
