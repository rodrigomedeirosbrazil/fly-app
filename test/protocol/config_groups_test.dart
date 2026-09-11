import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/config_groups.dart';

/// Builds a wire-shaped 17-byte ConfigThermal. Every setter is an offset
/// assertion: if the firmware moves a field, this helper changes and every
/// test leaning on it fails at once.
Uint8List thermalBytes({
  int motorReductionStartMc = 0,
  int motorMaxMc = 0,
  int escReductionStartMc = 0,
  int escMaxMc = 0,
  int motorTempSource = 0,
  int length = 17,
}) {
  final d = ByteData(17);
  d.setInt32(0, motorReductionStartMc, Endian.little);
  d.setInt32(4, motorMaxMc, Endian.little);
  d.setInt32(8, escReductionStartMc, Endian.little);
  d.setInt32(12, escMaxMc, Endian.little);
  d.setUint8(16, motorTempSource);
  return d.buffer.asUint8List().sublist(0, length);
}

void main() {
  test('the group id matches the firmware enum', () {
    expect(ConfigGroup.power.id, 0);
    expect(ConfigGroup.thermal.id, 1);
    expect(ConfigGroup.bms.id, 2);
    expect(ConfigGroup.system.id, 3);
  });

  test('every field lands where the header says it does', () {
    final c = ThermalConfig.decode(thermalBytes(
      motorReductionStartMc: 80000,
      motorMaxMc: 100000,
      escReductionStartMc: 70500,
      escMaxMc: 95250,
      motorTempSource: 1,
    ))!;

    expect(c.motorReductionStartC, closeTo(80.0, 1e-9));
    expect(c.motorMaxC, closeTo(100.0, 1e-9));
    expect(c.escReductionStartC, closeTo(70.5, 1e-9));
    expect(c.escMaxC, closeTo(95.25, 1e-9));
    expect(c.motorTempSource, 1);
  });

  test('thresholds are signed', () {
    final c = ThermalConfig.decode(thermalBytes(
      motorReductionStartMc: -5000,
      motorMaxMc: -1000,
    ))!;
    expect(c.motorReductionStartC, closeTo(-5.0, 1e-9));
    expect(c.motorMaxC, closeTo(-1.0, 1e-9));
  });

  test('a short payload is rejected whole', () {
    // At protocol version 1 no older group exists, so short is corruption.
    expect(ThermalConfig.decode(thermalBytes(length: 16)), isNull);
    expect(ThermalConfig.decode(const []), isNull);
  });

  test('a longer payload decodes its first 17 bytes', () {
    final padded = Uint8List(24)
      ..setRange(0, 17, thermalBytes(motorMaxMc: 100000));
    expect(ThermalConfig.decode(padded)!.motorMaxC, closeTo(100.0, 1e-9));
  });

  group('band sanity', () {
    ThermalConfig config(int startMc, int maxMc) => ThermalConfig.decode(
          thermalBytes(
            motorReductionStartMc: startMc,
            motorMaxMc: maxMc,
            escReductionStartMc: startMc,
            escMaxMc: maxMc,
          ),
        )!;

    test('a configured pair is a band', () {
      final c = config(80000, 100000);
      expect(c.motorBandStartC, closeTo(80.0, 1e-9));
      expect(c.motorBandEndC, closeTo(100.0, 1e-9));
      expect(c.escBandStartC, closeTo(80.0, 1e-9));
      expect(c.escBandEndC, closeTo(100.0, 1e-9));
    });

    test('an unconfigured NVS of zeros is not a band', () {
      // Zero to zero would otherwise paint the whole dial red.
      final c = config(0, 0);
      expect(c.motorBandStartC, isNull);
      expect(c.motorBandEndC, isNull);
    });

    test('a start at or past the end is not a band', () {
      expect(config(100000, 100000).motorBandStartC, isNull);
      expect(config(110000, 100000).motorBandStartC, isNull);
    });

    test('a negative start is not a band', () {
      expect(config(-1000, 100000).motorBandStartC, isNull);
    });

    test('motor and ESC are judged independently', () {
      final c = ThermalConfig.decode(thermalBytes(
        motorReductionStartMc: 80000,
        motorMaxMc: 100000,
        escReductionStartMc: 0,
        escMaxMc: 0,
      ))!;
      expect(c.motorBandStartC, closeTo(80.0, 1e-9));
      expect(c.escBandStartC, isNull,
          reason: 'one sensor unconfigured must not cost the other its band');
    });
  });
}
