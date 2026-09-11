import 'telemetry_frame.dart';

/// Decodes one `$XCTOD` line into a [TelemetryFrame].
///
/// The wire format is duplicated from `fly-controller`'s `src/Xctod/Xctod.cpp`;
/// there is no shared package between the two repos. If the firmware changes
/// the field list, this file and its tests change with it.
class XctodParser {
  static const String prefix = r'$XCTOD';

  /// Number of comma-separated fields after the prefix token.
  static const int fieldCount = 16;

  /// Returns null when [line] is not a well-formed frame. The caller counts
  /// rejections; nothing partial is ever handed to the UI.
  static TelemetryFrame? parse(String line, {required DateTime receivedAt}) {
    final parts = line.trim().split(',');
    if (parts.length != fieldCount + 1) return null;
    if (parts.first != prefix) return null;

    final f = parts.sublist(1);

    // An empty field is a valid statement ("this reading is not available").
    // A non-empty field that fails to parse is a corrupt line. The two must not
    // be conflated: the first is normal, the second means the frame is garbage.
    var corrupt = false;

    int? optInt(String s) {
      if (s.isEmpty) return null;
      final v = int.tryParse(s);
      if (v == null) corrupt = true;
      return v;
    }

    double? optDouble(String s) {
      if (s.isEmpty) return null;
      final v = double.tryParse(s);
      if (v == null) corrupt = true;
      return v;
    }

    final socCoulomb = optInt(f[0]);
    final socVoltage = optInt(f[1]);
    final voltage = optDouble(f[2]);
    final powerKw = optDouble(f[3]);
    final throttlePct = optInt(f[4]);
    final throttleRaw = optInt(f[5]);
    final powerPct = optInt(f[6]);
    final motorTempC = optInt(f[7]);
    final rpm = optInt(f[9]);
    final currentA = optInt(f[10]);
    final escTempC = optInt(f[11]);
    final status = f[12];
    final bmsMaxTempC = optInt(f[13]);
    final cellMinMv = optInt(f[14]);
    final cellMaxMv = optInt(f[15]);

    if (corrupt) return null;

    // These five are unconditional in the firmware. Empty means the line is
    // malformed, not that a sensor is missing.
    if (socCoulomb == null ||
        socVoltage == null ||
        throttlePct == null ||
        throttleRaw == null ||
        powerPct == null ||
        status.isEmpty) {
      return null;
    }

    return TelemetryFrame(
      socCoulomb: socCoulomb,
      socVoltage: socVoltage,
      voltage: voltage,
      powerKw: powerKw,
      throttlePct: throttlePct,
      throttleRaw: throttleRaw,
      powerPct: powerPct,
      motorTempC: motorTempC?.toDouble(),
      motorTempSource: _source(f[8]),
      rpm: rpm,
      currentA: currentA?.toDouble(),
      escTempC: escTempC?.toDouble(),
      armState: status == 'ARMED' ? ArmState.armed : ArmState.disarmed,
      disarmReason: _reason(status),
      rawDisarmCode: _reason(status) == DisarmReason.unknown ? status : null,
      bmsMaxTempC: bmsMaxTempC,
      cellMinMv: cellMinMv,
      cellMaxMv: cellMaxMv,
      receivedAt: receivedAt,
    );
  }

  /// An unrecognised source degrades to [MotorTempSource.none] rather than
  /// rejecting the frame. If a future firmware adds a third sensor, the badge
  /// disappears and every other reading keeps flowing — blacking out the whole
  /// instrument over a label would be the worse failure.
  static MotorTempSource _source(String s) => switch (s) {
        'can' => MotorTempSource.can,
        'ntc' => MotorTempSource.ntc,
        _ => MotorTempSource.none,
      };

  /// Maps the sentence's status text onto the shared reason enum. `ARMED` and
  /// `DISARMED` carry no fault; anything else is a code, and one this app does
  /// not recognise is kept as raw text rather than dropped.
  static DisarmReason _reason(String status) => switch (status) {
        'ARMED' || 'DISARMED' => DisarmReason.none,
        'MANUAL' => DisarmReason.manual,
        'THR ERR' => DisarmReason.throttleWiredInvalid,
        'LINK ERR' => DisarmReason.throttleLinkLost,
        'MOT ERR' => DisarmReason.motorTempLost,
        'ESC ERR' => DisarmReason.escTempLost,
        'BATT ERR' => DisarmReason.batteryVoltageLost,
        'MOT SRC' => DisarmReason.motorTempSourceChanged,
        _ => DisarmReason.unknown,
      };
}
