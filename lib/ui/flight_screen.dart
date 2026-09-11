import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/telemetry_frame.dart';
import 'widgets/dial.dart';

/// Number of series cells. The firmware has no support for other pack sizes, so
/// this is deliberately a constant and not a setting — the same choice the web
/// telemetry page made. An estimate derived from it is marked with a tilde.
const int _seriesCells = 14;

/// The instrument.
///
/// Card stack, fixed order: status, battery, instruments, throttle, drawer bar.
/// Nothing is added to or removed from that stack at runtime, so an alert can
/// never shift a number the pilot is in the middle of reading — a fault shows
/// as a chip in space the status row already reserves.
///
/// Two things the web panel has are absent here and cannot be added from this
/// data: the flight clock and the red reduction band on the thermal dials.
/// Neither `sessionSec` nor the thermal thresholds travel over the $XCTOD
/// stream. They arrive with phase 2.
class FlightScreen extends StatefulWidget {
  const FlightScreen({super.key, required this.frame, required this.stale});

  final TelemetryFrame? frame;

  /// True when a frame was received but has aged out.
  final bool stale;

  @override
  State<FlightScreen> createState() => _FlightScreenState();
}

class _FlightScreenState extends State<FlightScreen> {
  bool _drawerOpen = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.frame;

    // Back is the one input Android has and iOS does not. The overlay below
    // is a Stack child rather than a route, so there is nothing for back to
    // pop and unguarded it pops the app — one stray tap closing the
    // instrument panel in flight. canPop stays false with the overlay closed
    // too: leaving mid-flight is home or the app switcher, deliberately.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (_drawerOpen) setState(() => _drawerOpen = false);
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                child: Column(
                  children: [
                    _StatusRow(frame: f, stale: widget.stale),
                    const SizedBox(height: 8),
                    Expanded(child: _BatteryCard(frame: f)),
                    const SizedBox(height: 8),
                    _InstrumentRow(frame: f),
                    const SizedBox(height: 8),
                    _ThrottleCard(frame: f),
                    const SizedBox(height: 8),
                    _DrawerBar(onTap: () => setState(() => _drawerOpen = true)),
                  ],
                ),
              ),
              // In the tree, not a pushed route. A modal route builds once
              // from the frame captured when it opened and never sees
              // another, so the readings behind it silently freeze at 1 Hz.
              if (_drawerOpen)
                _SecondaryData(
                  frame: f,
                  onClose: () => setState(() => _drawerOpen = false),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded surface every band sits on.
class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = const EdgeInsets.all(10)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.frame, required this.stale});

  final TelemetryFrame? frame;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = frame;

    late final String text;
    late final Color color;

    if (f == null) {
      text = stale ? 'SEM SINAL' : 'AGUARDANDO';
      color = stale ? theme.colorScheme.error : theme.colorScheme.outline;
    } else if (f.disarmCode != null) {
      text = f.disarmCode!;
      color = theme.colorScheme.error;
    } else if (f.isArmed) {
      text = 'ARMADO';
      color = theme.colorScheme.error;
    } else {
      text = 'DESARMADO';
      color = theme.colorScheme.outline;
    }

    // Fixed height: the chips change colour and text, never the layout.
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (f != null && !stale)
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
          ),
          const SizedBox(width: 10),
          _Chip(text: text, color: color),
          const Spacer(),
          if (f != null && f.isLimited)
            _Chip(
              text: 'DISPONÍVEL ${f.powerPct} %',
              color: theme.colorScheme.error,
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// The dominant card: state of charge as a large dial, with pack voltage and
/// current beneath it. Those two are secondary to the gauge and sized to say so
/// — three numbers at equal weight read as one number.
class _BatteryCard extends StatefulWidget {
  const _BatteryCard({required this.frame});

  final TelemetryFrame? frame;

  @override
  State<_BatteryCard> createState() => _BatteryCardState();
}

class _BatteryCardState extends State<_BatteryCard> {
  static const String _prefKey = 'voltMode';

  bool _perCell = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefKey);
      if (saved != null && mounted) setState(() => _perCell = saved);
    } catch (_) {
      // Storage can be unavailable (restricted profile, blocked site data).
      // The default view is correct without it; never let this kill the screen.
    }
  }

  Future<void> _toggle() async {
    setState(() => _perCell = !_perCell);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, _perCell);
    } catch (_) {
      // Same reasoning: the toggle still works for this session.
    }
  }

  /// Per-cell prefers the BMS minimum cell — a measurement. Falling back to
  /// pack voltage over [_seriesCells] is a mean dressed up as a minimum, and
  /// says so with a tilde.
  ({String text, String unit})? _perCellReading(TelemetryFrame f) {
    final min = f.cellMinMv;
    if (min != null) {
      return (text: (min / 1000).toStringAsFixed(2), unit: 'V/cél');
    }
    final v = f.voltage;
    if (v == null) return null;
    return (text: '~${(v / _seriesCells).toStringAsFixed(2)}', unit: 'V/cél');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = widget.frame;

    String? voltageText;
    var voltageUnit = 'V';
    if (f != null) {
      if (_perCell) {
        final reading = _perCellReading(f);
        voltageText = reading?.text;
        voltageUnit = reading?.unit ?? 'V/cél';
      } else {
        voltageText = f.voltage?.toStringAsFixed(2);
      }
    }

    return _Card(
      child: Column(
        children: [
          Expanded(
            child: Dial(
              value: f?.socCoulomb.toDouble(),
              max: 100,
              unit: '%',
              label: 'BATERIA',
              showScale: true,
            ),
          ),
          const SizedBox(height: 6),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 6),
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  child: _Reading(
                    // The arrows mark the cell as switchable, as the web panel
                    // does; the unit changes with the mode so a per-cell 3.71
                    // can never be read as a flat pack.
                    label: 'TENSÃO ⇆',
                    value: voltageText,
                    unit: voltageUnit,
                    onTap: f == null ? null : _toggle,
                  ),
                ),
                // No current sensing (XAG) drops the cell entirely and lets the
                // voltage centre, rather than reserving space for a dash.
                if (f?.currentA != null) ...[
                  VerticalDivider(
                      width: 1, color: theme.colorScheme.outlineVariant),
                  Expanded(
                    child: _Reading(
                      label: 'CORRENTE',
                      value: f!.currentA!.round().toString(),
                      unit: 'A',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Label above, number and small adjacent unit below. A null value is a dash
/// with no unit — the controller said it has no reading, and a zero would read
/// as a measurement.
class _Reading extends StatelessWidget {
  const _Reading({
    required this.label,
    required this.value,
    required this.unit,
    this.onTap,
  });

  final String label;
  final String? value;
  final String unit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value ?? '–',
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    height: 1.0,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: 3),
                  Text(
                    unit,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Power, then the two temperatures.
///
/// Only the temperatures get dials. Power has no maximum, so a circular gauge
/// would have to invent a full scale — and a needle at 80% of an invented scale
/// reads as a real limit.
class _InstrumentRow extends StatelessWidget {
  const _InstrumentRow({required this.frame});

  final TelemetryFrame? frame;

  @override
  Widget build(BuildContext context) {
    final f = frame;

    return SizedBox(
      height: 118,
      child: Row(
        children: [
          if (f?.powerKw != null)
            Expanded(
              child: _Card(
                child: _Readout(
                  label: 'POTÊNCIA',
                  value: f!.powerKw!.toStringAsFixed(1),
                  unit: 'kW',
                ),
              ),
            ),
          if (f?.powerKw != null) const SizedBox(width: 8),
          Expanded(
            child: _Card(
              child: Dial(
                value: f?.motorTempC,
                max: 140,
                unit: '°C',
                caption: 'MOTOR',
                badge: switch (f?.motorTempSource) {
                  MotorTempSource.can => 'CAN',
                  MotorTempSource.ntc => 'NTC',
                  _ => null,
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Card(
              child: Dial(
                value: f?.escTempC,
                max: 140,
                unit: '°C',
                caption: 'ESC',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled number with no gauge behind it, for quantities with no full
/// scale. Sized like the dials beside it: a fixed point size looks right on the
/// phone it was written on and wraps on a narrower one.
class _Readout extends StatelessWidget {
  const _Readout({required this.label, required this.value, required this.unit});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(
      fontSize: 11,
      letterSpacing: 1.5,
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label, maxLines: 1, softWrap: false, style: muted),
        Flexible(
          child: FittedBox(
            child: Text(
              value,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                height: 1.2,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        Text(unit, maxLines: 1, softWrap: false, style: muted),
      ],
    );
  }
}

class _ThrottleCard extends StatelessWidget {
  const _ThrottleCard({required this.frame});

  final TelemetryFrame? frame;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = frame;
    final pct = f?.throttlePct ?? 0;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ACELERADOR',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                f == null ? '–' : '$pct %',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.secondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 10,
              color: theme.colorScheme.secondary,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom bar: names what is behind it rather than being a bare chevron.
class _DrawerBar extends StatelessWidget {
  const _DrawerBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Mais dados',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: _Card(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.keyboard_arrow_up, size: 20),
              const SizedBox(width: 8),
              Text(
                'MAIS DADOS',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'RPM · BMS · CÉLULAS · LEITURAS',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.0,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The readings the panel deliberately does not show.
///
/// Six fields arrive in every frame that the panel has no room for. They are
/// reachable but overlaid, so the BMS connecting or dropping cannot re-lay out
/// the numbers the pilot is reading.
class _SecondaryData extends StatelessWidget {
  const _SecondaryData({required this.frame, required this.onClose});

  final TelemetryFrame? frame;
  final VoidCallback onClose;

  /// An unavailable reading is a dash. Same rule as the panel.
  static String _or(Object? value, String suffix) =>
      value == null ? '–' : '$value$suffix';

  String get _cells {
    final f = frame;
    if (f == null || f.cellMinMv == null || f.cellMaxMv == null) return '–';
    return '${f.cellMinMv} / ${f.cellMaxMv} mV';
  }

  String get _source => switch (frame?.motorTempSource) {
        MotorTempSource.can => 'CAN',
        MotorTempSource.ntc => 'NTC',
        _ => '–',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = frame;

    final rows = <(String, String)>[
      ('Carga (por tensão)', _or(f?.socVoltage, ' %')),
      ('RPM', _or(f?.rpm, '')),
      ('Acelerador (bruto)', _or(f?.throttleRaw, '')),
      ('Temp. máx. BMS', _or(f?.bmsMaxTempC, ' °C')),
      ('Células mín / máx', _cells),
      ('Origem temp. motor', _source),
    ];

    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: ColoredBox(
          color: Colors.black54,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: () {},
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: 'Fechar',
                        child: IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down),
                          onPressed: onClose,
                        ),
                      ),
                      for (final (label, value) in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                label,
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              Text(
                                value,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
