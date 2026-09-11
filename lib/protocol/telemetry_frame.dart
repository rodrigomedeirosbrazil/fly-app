/// Which sensor fed the motor temperature reading.
///
/// The Tmotor build has two sources behind one number (ESC over CAN, or a local
/// NTC fallback); the XAG build always reports [none].
///
/// The order here does NOT match the firmware's `MotorTempOrigin`
/// (`None = 0, Can = 1, Ntc = 2`). Never index one by the other's integer.
enum MotorTempSource { can, ntc, none }

enum ArmState { armed, disarmed }

/// Sensor health, as reported by the binary protocol's two bits per signal.
///
/// Only [valid] means the number can be trusted. Zero is a legitimate
/// reading, so a reader must check the state rather than the value.
enum SignalState { absent, stale, invalid, valid }

/// Why the controller disarmed itself. Mirrors fly-controller's
/// `src/DisarmReason.h` by position: the binary protocol sends the index.
///
/// [unknown] is this repo's own addition, one past the firmware's last value,
/// so decoding a reason from a newer firmware degrades instead of throwing.
enum DisarmReason {
  none,
  manual,
  throttleWiredInvalid,
  throttleLinkLost,
  motorTempLost,
  escTempLost,
  batteryVoltageLost,
  motorTempSourceChanged,
  unknown,
}

/// Which limiter is currently cutting available power.
enum LimitCause { battery, motorTemp, escTemp }

/// The short fixed-width codes, identical to the firmware's
/// `disarmReasonCode()`. Manual and none are absent on purpose: the sentence
/// folded a pilot-initiated disarm into plain `DISARMED`, and so does this.
const Map<DisarmReason, String> _disarmCodes = {
  DisarmReason.throttleWiredInvalid: 'THR ERR',
  DisarmReason.throttleLinkLost: 'LINK ERR',
  DisarmReason.motorTempLost: 'MOT ERR',
  DisarmReason.escTempLost: 'ESC ERR',
  DisarmReason.batteryVoltageLost: 'BATT ERR',
  DisarmReason.motorTempSourceChanged: 'MOT SRC',
};

/// One decoded telemetry frame, from either source.
///
/// A null field means the reading is not available — either the source cannot
/// carry it at all, or the controller's own validity check failed. Null is
/// never rendered as zero: the UI hides the element instead. A `0 °C` printed
/// for a motor with no sensor reads as a cold motor.
///
/// The fields below [receivedAt] exist only on the binary `Fly Control`
/// service and are null on the `$XCTOD` path. [limitCauses] is the one to
/// watch: **null means "this source cannot say"**, while an empty set means
/// "nothing is limiting".
class TelemetryFrame {
  const TelemetryFrame({
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
    required this.disarmReason,
    required this.bmsMaxTempC,
    required this.cellMinMv,
    required this.cellMaxMv,
    required this.receivedAt,
    this.rawDisarmCode,
    this.sessionSec,
    this.hourMeterSec,
    this.uptimeSec,
    this.cellDeltaMv,
    this.limitCauses,
    this.powerScale,
    this.armCharge,
    this.motorTempState,
    this.escTempState,
    this.batteryVoltageState,
    this.isEngaged,
    this.hasTelemetry,
    this.powerControlEnabled,
    this.bmsConnected,
    this.bmsConfigured,
  });

  /// State of charge from coulomb counting, percent. Both sources always
  /// carry it.
  final int socCoulomb;

  /// State of charge inferred from pack voltage alone, percent. Null on the
  /// binary path when the battery-voltage signal is not [SignalState.valid] —
  /// the firmware has no validity concept for SoC, but this reading's
  /// trustworthiness follows the voltage it is derived from.
  final int? socVoltage;

  final double? voltage;
  final double? powerKw;
  final int throttlePct;

  /// Unmapped ADC reading behind [throttlePct]. Diagnostic only.
  final int throttleRaw;

  /// Available power after every limiter, percent. Below 100 means something
  /// is derating the motor.
  final int powerPct;

  final double? motorTempC;
  final MotorTempSource motorTempSource;
  final int? rpm;

  /// Amps. Signed: regen is a legitimate reading.
  final double? currentA;

  final double? escTempC;
  final ArmState armState;
  final DisarmReason disarmReason;

  /// The status text a `$XCTOD` sentence carried when it did not match any
  /// known reason. Preserved so an unrecognised code still reaches the pilot
  /// rather than vanishing into [DisarmReason.unknown].
  final String? rawDisarmCode;

  final int? bmsMaxTempC;
  final int? cellMinMv;
  final int? cellMaxMv;

  /// When this app received the frame. Freshness is measured from here, never
  /// from a UI tick.
  final DateTime receivedAt;

  // --- Binary source only. Null on the $XCTOD path. ---

  final Duration? sessionSec;
  final Duration? hourMeterSec;
  final Duration? uptimeSec;
  final int? cellDeltaMv;
  final Set<LimitCause>? limitCauses;
  final int? powerScale;
  final int? armCharge;
  final SignalState? motorTempState;
  final SignalState? escTempState;
  final SignalState? batteryVoltageState;
  final bool? isEngaged;
  final bool? hasTelemetry;
  final bool? powerControlEnabled;
  final bool? bmsConnected;
  final bool? bmsConfigured;

  bool get isArmed => armState == ArmState.armed;

  /// True when a limiter is currently cutting available power.
  bool get isLimited => powerPct < 100;

  /// Fault code to show, or null when there is nothing to report.
  ///
  /// A manual disarm folds into no code, exactly as the CSV sentence did —
  /// the firmware gives a pilot-initiated disarm the same weight as never
  /// having armed.
  String? get disarmCode {
    if (isArmed) return null;
    if (disarmReason == DisarmReason.unknown) return rawDisarmCode;
    return _disarmCodes[disarmReason];
  }
}
