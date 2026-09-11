import 'dart:typed_data';

import 'telemetry_frame.dart';

/// Decodes the `Fly Control` service's binary telemetry struct.
///
/// This is the second hand-duplicated fly-controller header in this repo, and
/// the cost of getting it wrong is the same as the first: fields are read **by
/// offset**, so a field that moves in the firmware decodes silently into the
/// wrong column here. The definition of record is
/// `src/BleControl/ControlProtocol.h`; `test/ControlProtocolTest.cpp` there
/// and `control_telemetry_codec_test.dart` here pin the same numbers, and they
/// are the only thing that catches a reorder.
///
/// Everything is little-endian and `#pragma pack(1)` — no padding anywhere.
class ControlTelemetryCodec {
  /// `ControlTelemetry.ver`. The firmware bumps it only when an existing field
  /// changes position or meaning, which makes it — and not `INFO`'s broader
  /// `protocolVersion` — the right gate for decoding this struct.
  static const int kStructVersion = 1;

  /// The size of the struct this app knows.
  ///
  /// A longer packet is future firmware and decodes fine. A shorter one is
  /// rejected whole rather than decoded into plausible nulls: at protocol
  /// version 1 no older struct exists, so a short packet can only be
  /// corruption or an ATT-truncated notification — which is exactly what the
  /// rejected-frame counter on the connection screen is there to catch. Lower
  /// this deliberately if a v0 struct ever turns out to exist.
  static const int kMinTelemetryLength = 56;

  // Availability: does this build and configuration produce the reading at
  // all? Sensor *health* is a different question, answered by signalStates.
  static const int _vCurrent = 1 << 0;
  static const int _vRpm = 1 << 1;
  static const int _vPowerKw = 1 << 2;
  static const int _vBms = 1 << 3;
  static const int _vBmsCells = 1 << 4;

  static const int _fArmed = 1 << 0;
  static const int _fEngaged = 1 << 1;
  static const int _fHasTelemetry = 1 << 2;
  static const int _fPowerControl = 1 << 3;
  static const int _fBmsConnected = 1 << 4;
  static const int _fBmsConfigured = 1 << 5;

  static const int _limitBattery = 1 << 0;
  static const int _limitMotorTemp = 1 << 1;
  static const int _limitEscTemp = 1 << 2;

  /// Returns null when the packet cannot be trusted. The caller counts
  /// rejections; nothing partial is ever handed to the UI.
  static TelemetryFrame? decode(
    List<int> bytes, {
    required DateTime receivedAt,
  }) {
    if (bytes.length < kMinTelemetryLength) return null;

    final d = ByteData.sublistView(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );

    if (d.getUint8(0) != kStructVersion) return null;

    final flags = d.getUint8(1);
    final validity = d.getUint16(2, Endian.little);
    final signalStates = d.getUint8(5);

    final motorState = _signal(signalStates, 4);
    final escState = _signal(signalStates, 2);
    final battState = _signal(signalStates, 0);

    bool has(int bit) => validity & bit != 0;
    bool flag(int bit) => flags & bit != 0;

    final limits = d.getUint8(13);

    return TelemetryFrame(
      socCoulomb: d.getUint8(7),
      // The firmware has no validity concept for SoC, but a percentage
      // derived from a voltage it distrusts is not a reading either.
      socVoltage: battState == SignalState.valid ? d.getUint8(8) : null,
      voltage: battState == SignalState.valid
          ? d.getUint16(14, Endian.little) / 1000.0
          : null,
      powerKw: has(_vPowerKw) ? d.getUint16(18, Endian.little) / 10.0 : null,
      throttlePct: d.getUint8(9),
      throttleRaw: d.getUint16(16, Endian.little),
      powerPct: d.getUint8(10),
      motorTempC: motorState == SignalState.valid
          ? d.getInt32(28, Endian.little) / 1000.0
          : null,
      motorTempSource: _source(d.getUint8(6)),
      rpm: has(_vRpm) ? d.getUint32(24, Endian.little) : null,
      currentA: has(_vCurrent) ? d.getInt32(20, Endian.little) / 1000.0 : null,
      escTempC: escState == SignalState.valid
          ? d.getInt32(32, Endian.little) / 1000.0
          : null,
      armState: flag(_fArmed) ? ArmState.armed : ArmState.disarmed,
      disarmReason: _reason(d.getUint8(4)),
      bmsMaxTempC: has(_vBms) ? d.getInt16(50, Endian.little) : null,
      cellMinMv: has(_vBmsCells) ? d.getUint16(44, Endian.little) : null,
      cellMaxMv: has(_vBmsCells) ? d.getUint16(46, Endian.little) : null,
      cellDeltaMv: has(_vBmsCells) ? d.getUint16(48, Endian.little) : null,
      receivedAt: receivedAt,
      sessionSec: Duration(seconds: d.getUint32(36, Endian.little)),
      hourMeterSec: Duration(seconds: d.getUint32(40, Endian.little)),
      uptimeSec: Duration(seconds: d.getUint32(52, Endian.little)),
      // An empty set says "nothing is limiting"; null would say "this source
      // cannot tell you", which is the $XCTOD path's answer, not this one's.
      limitCauses: {
        if (limits & _limitBattery != 0) LimitCause.battery,
        if (limits & _limitMotorTemp != 0) LimitCause.motorTemp,
        if (limits & _limitEscTemp != 0) LimitCause.escTemp,
      },
      powerScale: d.getUint8(11),
      armCharge: d.getUint8(12),
      motorTempState: motorState,
      escTempState: escState,
      batteryVoltageState: battState,
      isEngaged: flag(_fEngaged),
      hasTelemetry: flag(_fHasTelemetry),
      powerControlEnabled: flag(_fPowerControl),
      bmsConnected: flag(_fBmsConnected),
      bmsConfigured: flag(_fBmsConfigured),
    );
  }

  /// Two bits per signal, packed by the firmware's `packSignalStates`.
  static SignalState _signal(int packed, int shift) =>
      SignalState.values[(packed >> shift) & 0x03];

  /// Mapped, never indexed: the firmware's `MotorTempOrigin` is
  /// `{None = 0, Can = 1, Ntc = 2}` and the Dart enum is declared in a
  /// different order. An unrecognised value drops the badge rather than the
  /// whole instrument.
  static MotorTempSource _source(int v) => switch (v) {
        1 => MotorTempSource.can,
        2 => MotorTempSource.ntc,
        _ => MotorTempSource.none,
      };

  /// Positional, matching the firmware's `DisarmReason`. [DisarmReason.unknown]
  /// is this repo's own trailing member, so a reason from a newer firmware
  /// degrades instead of throwing.
  static DisarmReason _reason(int v) {
    final known = DisarmReason.values.length - 1; // excludes `unknown`
    return v < known ? DisarmReason.values[v] : DisarmReason.unknown;
  }
}
