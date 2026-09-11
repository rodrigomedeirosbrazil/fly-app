import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/settings_validation.dart';

void main() {
  group('power ranges, mirrored from the firmware', () {
    SettingsError power({
      int capacityMah = 20000,
      int minMv = 42000,
      int maxMv = 58800,
    }) =>
        validatePowerRanges(
          capacityMah: capacityMah,
          minVoltageMv: minMv,
          maxVoltageMv: maxMv,
        );

    test('a normal pack validates', () {
      expect(power(), SettingsError.none);
    });

    test('capacity spans 1000 to 65000 inclusive', () {
      expect(power(capacityMah: 1000), SettingsError.none);
      expect(power(capacityMah: 65000), SettingsError.none);
      expect(power(capacityMah: 999), SettingsError.capacityRange);
      expect(power(capacityMah: 65001), SettingsError.capacityRange);
    });

    test('minimum voltage spans 2500 to 63000 inclusive', () {
      expect(power(minMv: 2500), SettingsError.none);
      expect(power(minMv: 63000, maxMv: 63000), SettingsError.none);
      expect(power(minMv: 2499), SettingsError.minVoltageRange);
      expect(power(minMv: 63001), SettingsError.minVoltageRange);
    });

    test('maximum voltage spans 2500 to 63000 inclusive', () {
      expect(power(minMv: 2500, maxMv: 2500), SettingsError.none);
      expect(power(maxMv: 63000), SettingsError.none);
      expect(power(maxMv: 2499), SettingsError.maxVoltageRange);
      expect(power(maxMv: 63001), SettingsError.maxVoltageRange);
    });

    test('the divider ratio spans 1.0 to 100.0 inclusive', () {
      expect(validateDividerRatio(1.0), SettingsError.none);
      expect(validateDividerRatio(100.0), SettingsError.none);
      expect(validateDividerRatio(0.99), SettingsError.dividerRatioRange);
      expect(validateDividerRatio(100.01), SettingsError.dividerRatioRange);
    });
  });

  group('thermal ranges, mirrored from the firmware', () {
    SettingsError thermal({
      double motorStart = 80,
      double motorMax = 100,
      double escStart = 70,
      double escMax = 95,
    }) =>
        validateThermalRanges(
          motorReductionStartC: motorStart,
          motorMaxC: motorMax,
          escReductionStartC: escStart,
          escMaxC: escMax,
        );

    test('a normal configuration validates', () {
      expect(thermal(), SettingsError.none);
    });

    test('temperatures span 0 to 150 °C inclusive', () {
      expect(thermal(motorStart: 0, motorMax: 0), SettingsError.none);
      expect(thermal(motorStart: 150, motorMax: 150), SettingsError.none);
      expect(thermal(motorMax: 150.001), SettingsError.motorTempRange);
      expect(thermal(motorStart: -0.001), SettingsError.motorTempRange);
    });

    test('motor and ESC report their own error', () {
      expect(thermal(motorMax: 200), SettingsError.motorTempRange);
      expect(thermal(escMax: 200), SettingsError.escTempRange);
    });

    test('the motor temperature source is 0 or 1', () {
      expect(validateMotorTempSource(0), SettingsError.none);
      expect(validateMotorTempSource(1), SettingsError.none);
      expect(validateMotorTempSource(2), SettingsError.motorTempSourceInvalid);
    });
  });

  group("ordering, which is this app's alone", () {
    // SettingsValidation.h states it has no ordering check on purpose: the web
    // portal never had one. The firmware therefore accepts a configuration
    // whose effect is to cut the motor.
    test('a reduction start at or above the maximum is refused', () {
      expect(
        validateThermalOrder(
          motorReductionStartC: 100,
          motorMaxC: 100,
          escReductionStartC: 70,
          escMaxC: 95,
        ),
        SettingsError.motorTempOrder,
        reason: 'Power::calcMotorTempLimit returns 0 outright when equal',
      );
      expect(
        validateThermalOrder(
          motorReductionStartC: 110,
          motorMaxC: 100,
          escReductionStartC: 70,
          escMaxC: 95,
        ),
        SettingsError.motorTempOrder,
      );
    });

    test('ESC ordering is judged separately from the motor', () {
      expect(
        validateThermalOrder(
          motorReductionStartC: 80,
          motorMaxC: 100,
          escReductionStartC: 95,
          escMaxC: 95,
        ),
        SettingsError.escTempOrder,
      );
    });

    test('a correctly ordered pair passes', () {
      expect(
        validateThermalOrder(
          motorReductionStartC: 80,
          motorMaxC: 100,
          escReductionStartC: 70,
          escMaxC: 95,
        ),
        SettingsError.none,
      );
    });

    test('a minimum voltage at or above the maximum is refused', () {
      expect(validateVoltageOrder(minVoltageMv: 58800, maxVoltageMv: 58800),
          SettingsError.voltageOrder);
      expect(validateVoltageOrder(minVoltageMv: 59000, maxVoltageMv: 58800),
          SettingsError.voltageOrder);
      expect(validateVoltageOrder(minVoltageMv: 42000, maxVoltageMv: 58800),
          SettingsError.none);
    });
  });

  group('the combined entry points the form calls', () {
    test('ranges are checked before ordering', () {
      // An out-of-range value is the more specific complaint, and reporting
      // the ordering instead would send the pilot to fix the wrong field.
      expect(
        validatePower(
          capacityMah: 999,
          minVoltageMv: 59000,
          maxVoltageMv: 58800,
          dividerRatio: 11.0,
        ),
        SettingsError.capacityRange,
      );
    });

    test('an ordering failure survives valid ranges', () {
      expect(
        validatePower(
          capacityMah: 20000,
          minVoltageMv: 59000,
          maxVoltageMv: 58800,
          dividerRatio: 11.0,
        ),
        SettingsError.voltageOrder,
      );
    });

    test('a wholly valid group passes both', () {
      expect(
        validatePower(
          capacityMah: 20000,
          minVoltageMv: 42000,
          maxVoltageMv: 58800,
          dividerRatio: 11.0,
        ),
        SettingsError.none,
      );
      expect(
        validateThermal(
          motorReductionStartC: 80,
          motorMaxC: 100,
          escReductionStartC: 70,
          escMaxC: 95,
          motorTempSource: 0,
        ),
        SettingsError.none,
      );
    });
  });

  group('the calibration reference, which only this app collects', () {
    // The portal bounds what the pilot reads off the BMS at 10-65 V before
    // computing a ratio from it. The firmware never sees this number -- it
    // only receives the ratio -- so nothing downstream would catch a typo.
    test('accepts a plausible pack voltage', () {
      expect(validateCalibrationReference(10), SettingsError.none);
      expect(validateCalibrationReference(51.2), SettingsError.none);
      expect(validateCalibrationReference(65), SettingsError.none);
    });

    test('refuses a reading no 14S pack produces', () {
      expect(validateCalibrationReference(9.99),
          SettingsError.calibrationReferenceRange);
      expect(validateCalibrationReference(65.01),
          SettingsError.calibrationReferenceRange);
      expect(validateCalibrationReference(0),
          SettingsError.calibrationReferenceRange);
    });

    test('has a message like every other error', () {
      expect(messageFor(SettingsError.calibrationReferenceRange), isNotNull);
    });
  });

  test('every error has a Portuguese message', () {
    for (final e in SettingsError.values) {
      final message = messageFor(e);
      if (e == SettingsError.none) {
        expect(message, isNull);
      } else {
        expect(message, isNotNull, reason: '$e');
        expect(message, isNotEmpty, reason: '$e');
      }
    }
  });

  group('parseSetting', () {
    test('reads a comma as the decimal separator', () {
      expect(parseSetting('3,15'), closeTo(3.15, 1e-9));
    });

    test('reads a dot too, and surrounding space', () {
      expect(parseSetting(' 3.15 '), closeTo(3.15, 1e-9));
    });

    test('an empty field is unanswered, not zero', () {
      expect(parseSetting(''), isNull);
      expect(parseSetting('   '), isNull);
    });

    test('text is null rather than a plausible zero', () {
      expect(parseSetting('abc'), isNull);
      expect(parseSetting('1.2.3'), isNull);
      expect(parseSetting('12v'), isNull);
    });
  });
}
