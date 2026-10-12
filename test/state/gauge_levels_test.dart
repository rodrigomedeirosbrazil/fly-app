import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/state/gauge_levels.dart';

TelemetryFrame _frame({
  double? voltage = 50.4,
  int? cellMinMv,
  double? motorTempC,
  double? escTempC,
}) =>
    TelemetryFrame(
      socCoulomb: 80,
      socVoltage: 80,
      voltage: voltage,
      powerKw: null,
      throttlePct: 0,
      throttleRaw: 0,
      powerPct: 100,
      motorTempC: motorTempC,
      motorTempSource: MotorTempSource.can,
      rpm: null,
      currentA: null,
      escTempC: escTempC,
      armState: ArmState.armed,
      disarmReason: DisarmReason.none,
      bmsMaxTempC: null,
      cellMinMv: cellMinMv,
      cellMaxMv: null,
      receivedAt: DateTime.utc(2026, 10, 12),
    );

ThermalConfig _thermal() => const ThermalConfig(
      motorReductionStartC: 80,
      motorMaxC: 110,
      escReductionStartC: 70,
      escMaxC: 100,
      motorTempSource: 0,
    );

void main() {
  group('levelFor', () {
    const t = [10.0, 20.0, 30.0];
    for (final (value, previous, expected) in const [
      (5.0, 0, 0),
      (10.0, 0, 1), // entering happens at the threshold
      (19.9, 0, 1),
      (20.0, 0, 2),
      (30.0, 0, 3),
      (99.0, 0, 3),
      (29.0, 3, 3), // within the hysteresis below 30, holds
      (28.0, 3, 2), // exactly 2 below: no longer holds
      (18.5, 2, 2),
      (17.0, 3, 1), // fell through two levels at once
      (7.0, 1, 0),
    ]) {
      test('$value from level $previous is $expected', () {
        expect(levelFor(value, t, previous: previous, hysteresis: 2), expected);
      });
    }

    test('without hysteresis the previous level is irrelevant', () {
      expect(levelFor(29.9, t, previous: 3), 2);
    });
  });

  group('thermalLevel, start 80 max 110', () {
    for (final (temp, previous, expected) in const [
      (60.0, ThermalLevel.ok, ThermalLevel.ok),
      (70.0, ThermalLevel.ok, ThermalLevel.near), // 10 below start
      (79.9, ThermalLevel.ok, ThermalLevel.near),
      (80.0, ThermalLevel.ok, ThermalLevel.ramp),
      (110.0, ThermalLevel.ok, ThermalLevel.over),
      (108.5, ThermalLevel.over, ThermalLevel.over),
      (108.0, ThermalLevel.over, ThermalLevel.ramp),
      (78.5, ThermalLevel.ramp, ThermalLevel.ramp),
      (78.0, ThermalLevel.ramp, ThermalLevel.near),
      (68.5, ThermalLevel.near, ThermalLevel.near),
      (68.0, ThermalLevel.near, ThermalLevel.ok),
    ]) {
      test('$temp °C from $previous is $expected', () {
        expect(thermalLevel(temp, 80, 110, previous: previous), expected);
      });
    }
  });

  test('only ramp and over colour a thermal gauge', () {
    expect(thermalZone(null), GaugeZone.normal);
    expect(thermalZone(ThermalLevel.ok), GaugeZone.normal);
    expect(thermalZone(ThermalLevel.near), GaugeZone.normal);
    expect(thermalZone(ThermalLevel.ramp), GaugeZone.caution);
    expect(thermalZone(ThermalLevel.over), GaugeZone.danger);
  });

  group('batteryZone', () {
    for (final (pct, zone) in const [
      (100.0, GaugeZone.normal),
      (10.1, GaugeZone.normal),
      (10.0, GaugeZone.caution),
      (5.1, GaugeZone.caution),
      (5.0, GaugeZone.danger),
      (0.0, GaugeZone.danger),
      (-3.0, GaugeZone.danger), // below the configured minimum
    ]) {
      test('$pct % is $zone', () => expect(batteryZone(pct), zone));
    }
  });

  group('voltageRange', () {
    PowerConfig power(int minMv, int maxMv) => PowerConfig(
          capacityMah: 20000,
          minVoltageMv: minMv,
          maxVoltageMv: maxMv,
          powerControlEnabled: true,
          voltageDividerRatio: 11,
        );

    test('the pack range comes from the Power group', () {
      final r = voltageRange(power(42000, 58800))!;
      expect(r.min, 42.0);
      expect(r.max, 58.8);
      expect(r.at(10), closeTo(43.68, 1e-9));
      expect(r.percentOf(50.8), closeTo(52.38, 0.01));
    });

    test('per cell divides by the series count', () {
      final r = voltageRange(power(42000, 58800), perCell: true)!;
      expect(r.min, closeTo(3.0, 1e-9));
      expect(r.max, closeTo(4.2, 1e-9));
    });

    test('no config, or numbers that are not a range, is no range', () {
      expect(voltageRange(null), isNull);
      expect(voltageRange(power(0, 58800)), isNull);
      expect(voltageRange(power(58800, 58800)), isNull);
      expect(voltageRange(power(58800, 42000)), isNull);
    });
  });

  group('perCellVolts', () {
    test('prefers the BMS minimum cell', () {
      final r = perCellVolts(_frame(cellMinMv: 3712))!;
      expect(r.volts, closeTo(3.712, 1e-9));
      expect(r.estimated, isFalse);
    });

    test('falls back to the pack over 14, marked as an estimate', () {
      final r = perCellVolts(_frame())!;
      expect(r.volts, closeTo(3.6, 1e-9));
      expect(r.estimated, isTrue);
    });

    test('no voltage and no cell is no reading', () {
      expect(perCellVolts(_frame(voltage: null)), isNull);
    });
  });

  group('ThermalHysteresis', () {
    test('is unknown without a config, so nothing claims a level', () {
      final h = ThermalHysteresis()..update(_frame(motorTempC: 95), null);
      expect(h.motor, isNull);
      expect(h.esc, isNull);
    });

    test('is unknown for a missing reading', () {
      final h = ThermalHysteresis()..update(_frame(), _thermal());
      expect(h.motor, isNull);
    });

    test('holds a level across the hysteresis between frames', () {
      final h = ThermalHysteresis()
        ..update(_frame(motorTempC: 81, escTempC: 50), _thermal());
      expect(h.motor, ThermalLevel.ramp);
      expect(h.esc, ThermalLevel.ok);

      h.update(_frame(motorTempC: 79, escTempC: 50), _thermal());
      expect(h.motor, ThermalLevel.ramp, reason: 'within 2 °C of the start');
    });

    test('the same frame applied twice changes nothing', () {
      final f = _frame(motorTempC: 79);
      final h = ThermalHysteresis()..update(f, _thermal());
      final first = h.motor;
      h.update(f, _thermal());
      expect(h.motor, first);
    });
  });
}
