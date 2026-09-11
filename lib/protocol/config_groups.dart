import 'dart:typed_data';

/// Series cells in the pack, mirroring the firmware's `BATTERY_CELL_COUNT`.
///
/// The firmware has no support for other pack sizes, so this is a constant
/// rather than a setting — the same choice the web portal made. It lives here
/// rather than in a widget because the flight panel and the settings screens
/// both convert pack voltage to per-cell with it, and a second copy would be
/// a second hand-copied firmware constant to keep in sync.
const int kSeriesCells = 14;

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

  Uint8List encode() {
    final d = ByteData(kLength);
    d.setInt32(0, (motorReductionStartC * 1000).round(), Endian.little);
    d.setInt32(4, (motorMaxC * 1000).round(), Endian.little);
    d.setInt32(8, (escReductionStartC * 1000).round(), Endian.little);
    d.setInt32(12, (escMaxC * 1000).round(), Endian.little);
    d.setUint8(16, motorTempSource);
    return d.buffer.asUint8List();
  }
}

/// The `Power` group: pack size, its voltage window, whether power control is
/// on, and the voltage divider ratio.
///
/// Little-endian, `#pragma pack(1)`, matching `ConfigPower` in the firmware's
/// `src/BleControl/ControlProtocol.h`.
class PowerConfig {
  const PowerConfig({
    required this.capacityMah,
    required this.minVoltageMv,
    required this.maxVoltageMv,
    required this.powerControlEnabled,
    required this.voltageDividerRatio,
  });

  static const int kLength = 9;

  final int capacityMah;
  final int minVoltageMv;
  final int maxVoltageMv;
  final bool powerControlEnabled;

  /// Sent as hundredths: the firmware stores a float that cannot be memcpy'd.
  final double voltageDividerRatio;

  /// Returns null below [kLength]. Longer decodes its first [kLength] bytes,
  /// so future firmware appending a field still works; shorter is corruption,
  /// same reasoning as every other group here.
  static PowerConfig? decode(List<int> bytes) {
    if (bytes.length < kLength) return null;

    final d = ByteData.sublistView(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );

    return PowerConfig(
      capacityMah: d.getUint16(0, Endian.little),
      minVoltageMv: d.getUint16(2, Endian.little),
      maxVoltageMv: d.getUint16(4, Endian.little),
      // Any non-zero is true. The firmware writes 1, but a C bool field read
      // as a byte is not contractually 0-or-1.
      powerControlEnabled: d.getUint8(6) != 0,
      voltageDividerRatio: d.getUint16(7, Endian.little) / 100.0,
    );
  }

  Uint8List encode() {
    final d = ByteData(kLength);
    d.setUint16(0, capacityMah, Endian.little);
    d.setUint16(2, minVoltageMv, Endian.little);
    d.setUint16(4, maxVoltageMv, Endian.little);
    d.setUint8(6, powerControlEnabled ? 1 : 0);
    d.setUint16(7, (voltageDividerRatio * 100).round(), Endian.little);
    return d.buffer.asUint8List();
  }
}

/// `ConfigBms`, 7 bytes: `[type u8][mac 6]`.
///
/// Same rules as the other groups: shorter is corruption and decodes to null,
/// longer decodes its known prefix so firmware that appends a field still
/// works.
class BmsConfig {
  const BmsConfig({required this.bmsType, required this.bmsMac});

  /// 0 none, 1 JBD, 2 Daly, 3 JK. Mirrors the firmware's own numbering; there
  /// is no Dart enum here because the value is written straight back and a
  /// type this app does not know must survive the round trip.
  final int bmsType;

  /// Six raw bytes. All zero means unset — see `mac_address.dart`.
  final List<int> bmsMac;

  static const int kLength = 7;

  static BmsConfig? decode(List<int> bytes) {
    if (bytes.length < kLength) return null;
    return BmsConfig(
      bmsType: bytes[0],
      bmsMac: List<int>.unmodifiable(bytes.sublist(1, 7)),
    );
  }

  Uint8List encode() {
    final out = Uint8List(kLength);
    out[0] = bmsType;
    out.setRange(1, 7, bmsMac);
    return out;
  }
}

/// `ConfigSystem`, 8 bytes: `[volume u8][throttleSource u8][mac 6]`.
class SystemConfig {
  const SystemConfig({
    required this.buzzerVolume,
    required this.throttleSource,
    required this.remoteMac,
  });

  /// 0–100.
  final int buzzerVolume;

  /// 0 wired, 1 wireless (ESP-NOW).
  final int throttleSource;

  /// The paired remote throttle. All zero means none — and this field is the
  /// **only** readback the pairing flow has, because `REMOTE_PAIR` answers
  /// `Ok` the moment it sets a flag, long before a remote is heard.
  final List<int> remoteMac;

  static const int kLength = 8;

  static SystemConfig? decode(List<int> bytes) {
    if (bytes.length < kLength) return null;
    return SystemConfig(
      buzzerVolume: bytes[0],
      throttleSource: bytes[1],
      remoteMac: List<int>.unmodifiable(bytes.sublist(2, 8)),
    );
  }

  Uint8List encode() {
    final out = Uint8List(kLength);
    out[0] = buzzerVolume;
    out[1] = throttleSource;
    out.setRange(2, 8, remoteMac);
    return out;
  }
}
