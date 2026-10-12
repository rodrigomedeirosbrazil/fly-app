import '../protocol/config_groups.dart';
import '../protocol/telemetry_frame.dart';

/// The colour a gauge is in. The whole arc takes it — never a band. The alert
/// card beside it shares these thresholds and their hysteresis, but it also
/// reflects the firmware's own `limitCauses`, so it may be amber while a dial
/// is still green. That is deliberate: the firmware is the truth about a
/// reduction, so do not "fix" it by ignoring `limitCauses`.
enum GaugeZone { normal, caution, danger }

/// A temperature against this pilot's thresholds. [near] is the margin below
/// the reduction start; [ramp] is the reduction itself; [over] is at or past
/// the maximum, where `Power::calcMotorTempLimit` holds power at zero.
enum ThermalLevel { ok, near, ramp, over }

/// Below the reduction start by at most this much counts as [ThermalLevel.near].
const double kNearMarginC = 10;

/// Leaving a thermal level needs the temperature this far below its
/// threshold. Without it a motor sitting on a stripe flips the card at 1 Hz.
const double kThermalHysteresisC = 2;

/// Battery and voltage thresholds, percent. Inclusive: 10 % is already amber.
const double kBatteryCautionPct = 10;
const double kBatteryDangerPct = 5;

/// Fixed full scales. Fixed so an arc's angle means the same quantity on
/// every aircraft — the reason the thermal scale is fixed too.
const double kTempFullScaleC = 140;
const double kPowerFullScaleKw = 18;
const double kCurrentFullScaleA = 300;
const double kRpmFullScale = 6000;

/// The highest threshold [value] has reached, 1-based; 0 when none.
///
/// [ascending] must be sorted. Entering a level happens at its threshold;
/// staying in it only needs [value] to remain within [hysteresis] below it,
/// counted from [previous]. Pure, so the same inputs always give the same
/// level — a rebuild of one frame cannot move it.
int levelFor(
  double value,
  List<double> ascending, {
  int previous = 0,
  double hysteresis = 0,
}) {
  for (var i = ascending.length - 1; i >= 0; i--) {
    final level = i + 1;
    if (value >= ascending[i]) return level;
    if (previous >= level && value > ascending[i] - hysteresis) return level;
  }
  return 0;
}

ThermalLevel thermalLevel(
  double tempC,
  double startC,
  double maxC, {
  ThermalLevel previous = ThermalLevel.ok,
}) =>
    ThermalLevel.values[levelFor(
      tempC,
      [startC - kNearMarginC, startC, maxC],
      previous: previous.index,
      hysteresis: kThermalHysteresisC,
    )];

/// "Near" is a card-only warning: the dial stays green until reduction starts.
GaugeZone thermalZone(ThermalLevel? level) => switch (level) {
      ThermalLevel.ramp => GaugeZone.caution,
      ThermalLevel.over => GaugeZone.danger,
      _ => GaugeZone.normal,
    };

GaugeZone batteryZone(double percent) => percent <= kBatteryDangerPct
    ? GaugeZone.danger
    : percent <= kBatteryCautionPct
        ? GaugeZone.caution
        : GaugeZone.normal;

/// A gauge's scale when it is not fixed.
class GaugeRange {
  const GaugeRange(this.min, this.max);

  final double min;
  final double max;

  double percentOf(double value) => (value - min) / (max - min) * 100;

  double at(double percent) => min + (max - min) * percent / 100;
}

/// The voltage scale, from the pilot's own Power group.
///
/// Null when there is no group or its numbers do not form a range: a scale
/// the app invented would look like information.
GaugeRange? voltageRange(PowerConfig? config, {bool perCell = false}) {
  if (config == null) return null;
  final lo = config.minVoltageMv / 1000;
  final hi = config.maxVoltageMv / 1000;
  if (lo <= 0 || hi <= lo) return null;
  final divisor = perCell ? kSeriesCells : 1;
  return GaugeRange(lo / divisor, hi / divisor);
}

/// Per-cell voltage: the BMS minimum cell — a measurement — or the pack over
/// [kSeriesCells], which is a mean and says so through [estimated].
({double volts, bool estimated})? perCellVolts(TelemetryFrame f) {
  final min = f.cellMinMv;
  if (min != null) return (volts: min / 1000, estimated: false);
  final v = f.voltage;
  if (v == null) return null;
  return (volts: v / kSeriesCells, estimated: true);
}

/// The two thermal levels, carried from frame to frame for the hysteresis.
///
/// Null means unknown — no valid band, or no reading — and nothing may claim
/// a thermal level from it.
class ThermalHysteresis {
  ThermalLevel? motor;
  ThermalLevel? esc;

  void update(TelemetryFrame f, ThermalConfig? config) {
    motor = _next(f.motorTempC, config?.motorBandStartC,
        config?.motorBandEndC, motor);
    esc = _next(f.escTempC, config?.escBandStartC, config?.escBandEndC, esc);
  }

  static ThermalLevel? _next(
    double? temp,
    double? start,
    double? end,
    ThermalLevel? previous,
  ) {
    if (temp == null || start == null || end == null) return null;
    return thermalLevel(temp, start, end,
        previous: previous ?? ThermalLevel.ok);
  }
}
