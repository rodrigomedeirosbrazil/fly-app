import 'dart:typed_data';

/// Which controller is on the other end. The firmware sends 1 for XAG and 3
/// for Tmotor; 2 is not assigned.
enum ControllerType { xag, tmotor, unknown }

/// The `INFO` characteristic: **at least** 28 bytes, static for the session.
///
/// Read once at discovery. Little-endian, `#pragma pack(1)`, matching
/// `ControlInfo` in the firmware's `src/BleControl/ControlProtocol.h`.
///
/// **Longer payloads are decoded as far as this build understands them.**
/// That is the append rule the protocol reserves: a field added at the end
/// moves nothing, so no version bump, and each side ignores what it does not
/// know. The build stamp is the first use of it — firmware without it reads
/// 28 bytes and the app shows the version alone.
class ControlInfo {
  const ControlInfo({
    required this.protocolVersion,
    required this.controllerType,
    required this.capabilities,
    required this.appVersion,
    this.buildDate,
    this.buildTime,
  });

  /// The minimum, not the size. A shorter payload is unusable; a longer one
  /// is newer firmware.
  static const int kLength = 28;

  static const int _buildDateOffset = 28;
  static const int _buildDateLength = 12; // __DATE__ is 11 chars plus NUL
  static const int _buildTimeOffset = 40;
  static const int _buildTimeLength = 9; // __TIME__ is 8 chars plus NUL

  /// Length of a payload carrying the build stamp.
  static const int kLengthWithBuildStamp =
      _buildTimeOffset + _buildTimeLength; // 49

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

  /// The firmware's `__DATE__`, e.g. `Sep 12 2026`. **Null on firmware that
  /// does not send it**, which is every build before this field existed — not
  /// an error, and not a reason to reject the payload.
  final String? buildDate;

  /// The firmware's `__TIME__`, e.g. `12:06:45`. Null with [buildDate].
  final String? buildTime;

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

    /// Reads a fixed-width NUL-*padded* field, or null when the payload
    /// stops short of it.
    ///
    /// NUL-padded rather than NUL-terminated: a string filling the whole
    /// field has no terminator at all, so this reads to the first NUL or to
    /// the end, whichever comes first. Trimming whitespace instead would eat
    /// legitimate spaces and leave the padding behind.
    String? text(int offset, int length) {
      if (data.length < offset + length) return null;
      final raw = data.sublist(offset, offset + length);
      final end = raw.indexOf(0);
      return String.fromCharCodes(end == -1 ? raw : raw.sublist(0, end));
    }

    final version = text(4, kLength - 4)!;

    // Empty rather than absent: the field is there and the firmware left it
    // blank. Reported as nothing to show, not as a blank line.
    String? stamp(int offset, int length) {
      final value = text(offset, length);
      return (value == null || value.isEmpty) ? null : value;
    }

    return ControlInfo(
      buildDate: stamp(_buildDateOffset, _buildDateLength),
      buildTime: stamp(_buildTimeOffset, _buildTimeLength),
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
