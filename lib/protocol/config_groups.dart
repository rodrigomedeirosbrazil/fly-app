import 'dart:typed_data';

/// The four configuration groups. `CFG_GET` and `CFG_SET` work on whole
/// groups because values like a reduction start and its maximum are only
/// meaningful validated as a pair.
enum ConfigGroup {
  power(0),
  thermal(1),
  bms(2),
  system(3);

  const ConfigGroup(this.id);

  /// The byte sent as the `CFG_GET` payload.
  final int id;
}

/// The `Thermal` group: four thresholds and the motor temperature source.
///
/// Little-endian, `#pragma pack(1)`, matching `ConfigThermal` in the
/// firmware's `src/BleControl/ControlProtocol.h`. Read **by offset**, with the
/// same hazard as every other hand-duplicated header here.
class ThermalConfig {
  const ThermalConfig({
    required this.motorReductionStartC,
    required this.motorMaxC,
    required this.escReductionStartC,
    required this.escMaxC,
    required this.motorTempSource,
  });

  /// Size of the group this app knows.
  static const int kLength = 17;

  /// Where power reduction begins, °C. The firmware stores millicelsius.
  final double motorReductionStartC;

  /// Where power is fully cut, °C.
  final double motorMaxC;

  final double escReductionStartC;
  final double escMaxC;

  /// 0 = CAN, 1 = NTC. Only meaningful when the capability bit is set;
  /// decoded here and not yet used.
  final int motorTempSource;

  /// Returns null when the payload is not at least the known size.
  ///
  /// Longer decodes its first [kLength] bytes, so future firmware appending a
  /// field still works. Shorter is discarded: at protocol version 1 no older
  /// group exists, so a short one is corruption, and thresholds decoded from
  /// a truncated group would paint a red band at an invented temperature.
  static ThermalConfig? decode(List<int> bytes) {
    if (bytes.length < kLength) return null;

    final d = ByteData.sublistView(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );

    return ThermalConfig(
      motorReductionStartC: d.getInt32(0, Endian.little) / 1000.0,
      motorMaxC: d.getInt32(4, Endian.little) / 1000.0,
      escReductionStartC: d.getInt32(8, Endian.little) / 1000.0,
      escMaxC: d.getInt32(12, Endian.little) / 1000.0,
      motorTempSource: d.getUint8(16),
    );
  }

  /// The band's lower edge, or null when these two numbers do not form one.
  ///
  /// An unconfigured NVS returns zeros, and a band from 0 to 0 — or worse
  /// from 0 to the end of the scale — would paint the whole dial red.
  /// Numbers that do not describe a range do not become one.
  double? get motorBandStartC => _bandStart(motorReductionStartC, motorMaxC);
  double? get motorBandEndC => _bandEnd(motorReductionStartC, motorMaxC);
  double? get escBandStartC => _bandStart(escReductionStartC, escMaxC);
  double? get escBandEndC => _bandEnd(escReductionStartC, escMaxC);

  static bool _isBand(double start, double end) => start > 0 && start < end;

  static double? _bandStart(double start, double end) =>
      _isBand(start, end) ? start : null;

  static double? _bandEnd(double start, double end) =>
      _isBand(start, end) ? end : null;
}
