import 'package:flutter/material.dart';

import '../../protocol/config_groups.dart';
import '../../protocol/telemetry_frame.dart';
import '../../state/gauge_levels.dart';
import '../../state/panel_layout_policy.dart';
import '../reading_text.dart';
import '../widgets/dial.dart';
import 'number_format.dart';

/// Rounded surface every panel element sits on.
///
/// The border is always drawn — transparent when there is nothing to say —
/// so a card that starts signalling never changes size.
class PanelCard extends StatelessWidget {
  const PanelCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(8),
    this.borderColor,
    this.fillColor,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;
  final Color? fillColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: fillColor ?? s.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            width: 2,
            color: borderColor ?? Colors.transparent,
          ),
        ),
        child: child,
      ),
    );
  }
}

/// The state chip's words and colour. Shared by the status row and the
/// details screen's fixed strip, which must say the same thing.
({String text, Color color}) statusChipFor(
  ColorScheme s,
  TelemetryFrame? f, {
  required bool stale,
  bool reconnecting = false,
}) {
  if (f == null) {
    return (
      text: !stale
          ? 'AGUARDANDO'
          : reconnecting
              ? 'RECONECTANDO'
              : 'SEM SINAL',
      color: stale ? s.error : s.outline,
    );
  }
  if (f.disarmCode != null) return (text: f.disarmCode!, color: s.error);
  if (f.isArmed) return (text: 'ARMADO', color: s.error);
  return (text: 'DESARMADO', color: s.outline);
}

Color zoneColor(ColorScheme s, GaugeZone z) => switch (z) {
      GaugeZone.normal => s.primary,
      GaugeZone.caution => s.tertiary,
      GaugeZone.danger => s.error,
    };

/// Amber where caution starts, red where danger does.
List<DialStripe> thresholdStripes(
  ColorScheme s, {
  required double? caution,
  required double? danger,
}) =>
    [
      if (caution != null) DialStripe(caution, s.tertiary),
      if (danger != null) DialStripe(danger, s.error),
    ];

/// A small "⇄" marking a card that switches what it shows on tap.
class SwitchMark extends StatelessWidget {
  const SwitchMark({super.key});

  @override
  Widget build(BuildContext context) => Positioned(
        top: 0,
        right: 2,
        child: Text('⇄',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline)),
      );
}

class BatteryGaugeCard extends StatelessWidget {
  const BatteryGaugeCard({super.key, required this.frame});

  final TelemetryFrame? frame;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final soc = frame?.socCoulomb.toDouble();
    return PanelCard(
      child: Dial(
        key: const Key('gauge-battery'),
        value: soc,
        max: 100,
        unit: '%',
        label: 'BATERIA',
        color: soc == null ? null : zoneColor(s, batteryZone(soc)),
        stripes: thresholdStripes(s,
            caution: kBatteryCautionPct, danger: kBatteryDangerPct),
      ),
    );
  }
}

class FlightTimesRow extends StatelessWidget {
  const FlightTimesRow({super.key, required this.frame});

  final TelemetryFrame? frame;

  @override
  Widget build(BuildContext context) {
    final session = frame?.sessionSec;
    final remaining = frame?.remainingMin;
    return Row(
      children: [
        Expanded(
          child: PanelCard(
            child: _Figure(
              label: 'TEMPO DE VOO',
              value: session == null ? null : clock(session),
              unit: 'min',
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Motor-on minutes from the controller's own estimate. A voltage-only
        // estimate does not follow the throttle, so it says so.
        Expanded(
          child: PanelCard(
            key: const Key('time-remaining'),
            child: _Figure(
              label: 'TEMPO RESTANTE',
              value: remaining == null ? null : '$remaining',
              unit: frame?.remainingByVoltage == true ? 'min · tensão' : 'min',
              note: 'indisponível',
            ),
          ),
        ),
      ],
    );
  }
}

/// Label above, number with its unit (or the reason it is missing) below.
class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    required this.unit,
    this.note,
  });

  final String label;
  final String? value;
  final String unit;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 11, color: s.onSurfaceVariant);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            maxLines: 1,
            softWrap: false,
            style: small.copyWith(
                letterSpacing: 1.5, fontWeight: FontWeight.w600)),
        FittedBox(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value ?? '–',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: value == null ? s.outline : s.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
              const SizedBox(width: 3),
              if (value != null) Text(unit, style: small),
              if (value == null && note != null) Text(note!, style: small),
            ],
          ),
        ),
      ],
    );
  }
}

class TemperatureGauge extends StatelessWidget {
  const TemperatureGauge({
    super.key,
    required this.dialKey,
    required this.caption,
    required this.value,
    required this.state,
    required this.badge,
    required this.start,
    required this.end,
    required this.level,
  });

  final Key dialKey;
  final String caption;
  final double? value;
  final SignalState? state;
  final String? badge;
  final double? start;
  final double? end;
  final ThermalLevel? level;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return PanelCard(
      child: Dial(
        key: dialKey,
        value: value,
        max: kTempFullScaleC,
        unit: '°C',
        caption: caption,
        badge: badge,
        note: signalNote(state),
        color: zoneColor(s, thermalZone(level)),
        stripes: thresholdStripes(s, caution: start, danger: end),
      ),
    );
  }
}

/// Throttle position, with the ceiling the limiters leave.
class ThrottleCard extends StatelessWidget {
  const ThrottleCard({super.key, required this.frame});

  final TelemetryFrame? frame;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final f = frame;
    final pct = f?.throttlePct ?? 0;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('ACELERAÇÃO',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                    color: s.onSurfaceVariant,
                  )),
              Text(f == null ? '–' : '$pct %',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: s.secondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ],
          ),
          const SizedBox(height: 6),
          // Past powerPct the controller delivers no more.
          LayoutBuilder(
            builder: (context, c) => Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    minHeight: 10,
                    color: s.secondary,
                    backgroundColor: s.surfaceContainerHighest,
                  ),
                ),
                if (f != null && f.isLimited)
                  Positioned(
                    key: const Key('throttle-ceiling'),
                    left: (c.maxWidth * f.powerPct / 100)
                        .clamp(0.0, c.maxWidth - 2),
                    top: -3,
                    bottom: -3,
                    child: Container(width: 2, color: s.error),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Voltage, power or current, RPM — whichever this aircraft can produce.
class BottomRowCards extends StatelessWidget {
  const BottomRowCards({
    super.key,
    required this.layout,
    required this.frame,
    required this.powerConfig,
    required this.perCell,
    required this.showCurrent,
    required this.onTogglePerCell,
    required this.onToggleCurrent,
  });

  final BottomRowLayout layout;
  final TelemetryFrame? frame;
  final PowerConfig? powerConfig;
  final bool perCell;
  final bool showCurrent;
  final VoidCallback onTogglePerCell;
  final VoidCallback onToggleCurrent;

  /// Why power, current or RPM is missing when the ESC has gone quiet. Takes
  /// the number's place; the card stays.
  String? get _noData => frame?.hasTelemetry == false ? 'SEM DADOS' : null;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    const gap = SizedBox(width: 8);
    return switch (layout) {
      BottomRowLayout.full => Row(children: [
          Expanded(child: _voltage(s, perCell, onTogglePerCell)),
          gap,
          Expanded(child: _power()),
          gap,
          Expanded(child: _rpm()),
        ]),
      BottomRowLayout.noRpm => Row(children: [
          Expanded(child: _voltage(s, perCell, onTogglePerCell)),
          gap,
          Expanded(child: _power()),
        ]),
      BottomRowLayout.voltageOnly => _wide(s),
    };
  }

  Dial _voltageDial(ColorScheme s, bool cell, {Key? key, String? caption}) {
    final f = frame;
    final range = voltageRange(powerConfig, perCell: cell);
    final reading = (cell && f != null) ? perCellVolts(f) : null;
    final value = cell ? reading?.volts : f?.voltage;
    return Dial(
      key: key,
      value: value,
      min: range?.min ?? 0,
      max: range?.max ?? 1,
      showArc: range != null,
      unit: 'V',
      caption: caption,
      note: signalNote(f?.batteryVoltageState),
      format: cell
          ? (v) => '${reading!.estimated ? '~' : ''}${decimal(v, 2)}'
          : (v) => decimal(v, 1),
      color: (value == null || range == null)
          ? null
          : zoneColor(s, batteryZone(range.percentOf(value))),
      stripes: range == null
          ? const []
          : thresholdStripes(s,
              caution: range.at(kBatteryCautionPct),
              danger: range.at(kBatteryDangerPct)),
    );
  }

  Widget _voltage(ColorScheme s, bool cell, VoidCallback onTap) => PanelCard(
        onTap: onTap,
        child: Stack(children: [
          _voltageDial(s, cell,
              key: const Key('gauge-voltage'),
              caption: cell ? 'CÉLULA' : 'TENSÃO'),
          const SwitchMark(),
        ]),
      );

  Widget _power() => PanelCard(
        onTap: onToggleCurrent,
        child: Stack(children: [
          showCurrent
              ? Dial(
                  key: const Key('gauge-current'),
                  value: frame?.currentA,
                  max: kCurrentFullScaleA,
                  unit: 'A',
                  caption: 'CORRENTE',
                  note: _noData,
                  format: (v) => v.round().toString(),
                )
              : Dial(
                  key: const Key('gauge-power'),
                  value: frame?.powerKw,
                  max: kPowerFullScaleKw,
                  unit: 'kW',
                  caption: 'POTÊNCIA',
                  note: _noData,
                  format: (v) => decimal(v, 1),
                ),
          const SwitchMark(),
        ]),
      );

  Widget _rpm() => PanelCard(
        child: Dial(
          key: const Key('gauge-rpm'),
          value: frame?.rpm?.toDouble(),
          max: kRpmFullScale,
          unit: '',
          caption: 'RPM',
          note: _noData,
          format: (v) => grouped(v.round()),
        ),
      );

  /// No current, no power, no RPM: the pack and the cell side by side, so
  /// the row is not left mostly empty. Nothing to switch, so no tap.
  Widget _wide(ColorScheme s) {
    final f = frame;
    final reading = f == null ? null : perCellVolts(f);
    return PanelCard(
      key: const Key('voltage-wide'),
      child: Row(children: [
        Expanded(
            child: _voltageDial(s, false,
                key: const Key('gauge-voltage'), caption: 'TENSÃO')),
        Expanded(
          child: _Figure(
            label: 'POR CÉLULA',
            value: reading == null
                ? null
                : '${reading.estimated ? '~' : ''}${decimal(reading.volts, 2)}',
            unit: 'V',
          ),
        ),
      ]),
    );
  }
}
