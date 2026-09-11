import 'dart:typed_data';

/// Which controller is on the other end. The firmware sends 1 for XAG and 3
/// for Tmotor; 2 is not assigned.
enum ControllerType { xag, tmotor, unknown }

/// The `INFO` characteristic: 28 bytes, static for the whole session.
///
/// Read once at discovery. Little-endian, `#pragma pack(1)`, matching
/// `ControlInfo` in the firmware's `src/BleControl/ControlProtocol.h`.
class ControlInfo {
  const ControlInfo({
    required this.protocolVersion,
    required this.controllerType,
    required this.capabilities,
    required this.appVersion,
  });

  static const int kLength = 28;

  static const int _capCanTelemetry = 1 << 0;
  static const int _capVoltageSensor = 1 << 1;
  static const int _capMotorTempSourceSel = 1 << 2;
  static const int _capRemoteLink = 1 << 3;

  /// `CONTROL_PROTOCOL_VERSION`. Recorded, and deliberately **not** used to
  /// gate telemetry decoding: it is bumped for changes anywhere in the
  /// protocol, including config opcodes the panel never touches. The telemetry
  /// struct carries its own `ver` for that job.
  final int protocolVersion;

  final ControllerType controllerType;
  final int capabilities;

  /// Firmware version, NUL-padding removed.
  final String appVersion;

  bool get hasCanTelemetry => capabilities & _capCanTelemetry != 0;
  bool get hasVoltageSensor => capabilities & _capVoltageSensor != 0;
  bool get hasSelectableMotorTempSource =>
      capabilities & _capMotorTempSourceSel != 0;
  bool get hasRemoteLink => capabilities & _capRemoteLink != 0;

  /// Returns null when the payload is not the expected size. The caller treats
  /// that as the control service being unusable and falls back to `$XCTOD`.
  static ControlInfo? decode(List<int> bytes) {
    if (bytes.length < kLength) return null;

    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final d = ByteData.sublistView(data);

    // char[24], NUL-*padded* rather than NUL-terminated: a version filling
    // all 24 bytes has no terminator at all, so read to the first NUL or to
    // the end, whichever comes first. Trimming whitespace instead would eat
    // legitimate spaces and leave the padding behind.
    final raw = data.sublist(4, kLength);
    final end = raw.indexOf(0);
    final version =
        String.fromCharCodes(end == -1 ? raw : raw.sublist(0, end));

    return ControlInfo(
      protocolVersion: d.getUint8(0),
      controllerType: switch (d.getUint8(1)) {
        1 => ControllerType.xag,
        3 => ControllerType.tmotor,
        _ => ControllerType.unknown,
      },
      capabilities: d.getUint16(2, Endian.little),
      appVersion: version,
    );
  }
}
