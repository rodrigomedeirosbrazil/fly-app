/// Which sensor fed the motor temperature reading.
///
/// The Tmotor build has two sources behind one number (ESC over CAN, or a local
/// NTC fallback); the XAG build always reports [none].
enum MotorTempSource { can, ntc, none }

/// Arming state as reported in field 13 of the `$XCTOD` line.
enum ArmState { armed, disarmed }

/// One decoded `$XCTOD` telemetry line.
///
/// Every nullable field means the controller's own validity check failed and it
/// transmitted an empty CSV field. Null is never to be rendered as zero: the UI
/// hides the element instead. A `0 °C` printed for a motor with no sensor reads
/// as a cold motor.
class XctodFrame {
  const XctodFrame({
    required this.socCoulomb,
    required this.socVoltage,
    required this.voltage,
    required this.powerKw,
    required this.throttlePct,
    required this.throttleRaw,
    required this.powerPct,
    required this.motorTempC,
    required this.motorTempSource,
    required this.rpm,
    required this.currentA,
    required this.escTempC,
    required this.armState,
    required this.disarmCode,
    required this.bmsMaxTempC,
    required this.cellMinMv,
    required this.cellMaxMv,
    required this.receivedAt,
  });

  /// State of charge from coulomb counting, percent.
  final int socCoulomb;

  /// State of charge inferred from pack voltage alone, percent.
  final int socVoltage;

  /// Pack voltage in volts.
  final double? voltage;

  /// Instantaneous power in kilowatts.
  final double? powerKw;

  /// Raw throttle position, percent of the calibrated range.
  final int throttlePct;

  /// Unmapped ADC reading behind [throttlePct]. Diagnostic only.
  final int throttleRaw;

  /// Available power after every limiter, percent. Below 100 means something
  /// is derating the motor.
  final int powerPct;

  final int? motorTempC;
  final MotorTempSource motorTempSource;
  final int? rpm;
  final int? currentA;
  final int? escTempC;

  final ArmState armState;

  /// Fault code when the controller disarmed itself, e.g. `MOT SRC`. Null when
  /// armed, and also null for a plain `DISARMED` — the firmware folds a
  /// pilot-initiated disarm into the same value as never having armed.
  final String? disarmCode;

  final int? bmsMaxTempC;
  final int? cellMinMv;
  final int? cellMaxMv;

  /// When this app received the line. Freshness is measured from here, never
  /// from a UI tick.
  final DateTime receivedAt;

  bool get isArmed => armState == ArmState.armed;

  /// True when a limiter is currently cutting available power.
  bool get isLimited => powerPct < 100;
}
