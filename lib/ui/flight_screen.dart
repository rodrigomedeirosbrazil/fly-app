import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/xctod_frame.dart';
import 'widgets/dial.dart';

/// The instrument. Purely presentational — it takes a frame and draws it, which
/// is what makes it testable without a radio.
///
/// The band stack is fixed: status, hero, instruments, throttle, drawer handle.
/// Nothing is added or removed at runtime, so an alert can never shift a number
/// the pilot is in the middle of reading.
///
/// The hero band absorbs the leftover height and its numbers grow into it; the
/// instrument row takes only what its dials need. The reverse left a void in
/// the middle of the panel with the primary readings stranded at 64 pt.
class FlightScreen extends StatelessWidget {
  const FlightScreen({super.key, required this.frame, required this.stale});

  final XctodFrame? frame;

  /// True when a frame was received but has aged out.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final f = frame;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The fixed bands are proportional to the viewport, not constant.
            // Held constant they add up to more than a small phone has and the
            // panel overflows by a few pixels -- which clips a reading rather
            // than shrinking it. Compressing continuously is what keeps every
            // band on screen from a 320x480 phone up to a tablet.
            final h = constraints.maxHeight;
            final pad = (h * 0.02).clamp(6.0, 12.0);
            final gap = (h * 0.015).clamp(4.0, 12.0);
            final instruments = (h * 0.24).clamp(92.0, 150.0);

            return Padding(
              padding: EdgeInsets.all(pad),
              child: Column(
                children: [
                  _StatusBand(frame: f, stale: stale),
                  SizedBox(height: gap),
                  Expanded(child: _HeroBand(frame: f)),
                  SizedBox(height: gap),
                  _InstrumentBand(frame: f, height: instruments),
                  SizedBox(height: gap),
                  _ThrottleBand(frame: f),
                  _DrawerHandle(frame: f),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StatusBand extends StatelessWidget {
  const _StatusBand({required this.frame, required this.stale});

  final XctodFrame? frame;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = frame;

    late final String text;
    late final Color color;

    if (f == null) {
      text = stale ? 'SEM SINAL' : 'AGUARDANDO';
      color = stale ? theme.colorScheme.error : theme.colorScheme.surfaceContainerHighest;
    } else if (f.disarmCode != null) {
      text = f.disarmCode!;
      color = theme.colorScheme.error;
    } else if (f.isArmed) {
      text = 'ARMED';
      color = theme.colorScheme.primary;
    } else {
      text = 'DISARMED';
      color = theme.colorScheme.surfaceContainerHighest;
    }

    // Fixed height: the chip changes colour and text, never the layout.
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              text,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const Spacer(),
          if (f != null && f.isLimited)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'DISPONÍVEL ${f.powerPct} %',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Number of series cells. The firmware has no support for other pack sizes, so
/// this is deliberately a constant and not a setting — the same choice the web
/// telemetry page made. An estimate derived from it is marked with a tilde.
const int _seriesCells = 14;

class _HeroBand extends StatefulWidget {
  const _HeroBand({required this.frame});

  final XctodFrame? frame;

  @override
  State<_HeroBand> createState() => _HeroBandState();
}

class _HeroBandState extends State<_HeroBand> {
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
      // Storage can be unavailable (blocked site data, restricted profile).
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

  /// Per-cell prefers the BMS minimum cell — a measured number. Falling back to
  /// pack voltage over [_seriesCells] is an estimate, and says so with a tilde.
  ({String text, String unit})? _perCellReading(XctodFrame f) {
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
    final f = widget.frame;

    String? voltageText;
    String voltageUnit = 'V';

    if (f != null) {
      if (_perCell) {
        final reading = _perCellReading(f);
        voltageText = reading?.text;
        voltageUnit = reading?.unit ?? 'V/cél';
      } else {
        voltageText = f.voltage?.toStringAsFixed(1);
      }
    }

    // Current is a primary load indicator and was arriving in every frame
    // unused. When it is unavailable the cell collapses and the remaining two
    // grow, rather than printing a zero amp draw.
    final showCurrent = f?.currentA != null;

    return Row(
      children: [
        Expanded(
          child: _HeroCell(
            label: 'BATERIA',
            value: f?.socCoulomb.toString(),
            unit: '%',
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: f == null ? null : _toggle,
            child: _HeroCell(
              label: 'TENSÃO',
              value: voltageText,
              unit: voltageUnit,
            ),
          ),
        ),
        if (showCurrent)
          Expanded(
            child: _HeroCell(
              label: 'CORRENTE',
              value: f!.currentA.toString(),
              unit: 'A',
            ),
          ),
      ],
    );
  }
}

class _HeroCell extends StatelessWidget {
  const _HeroCell({required this.label, required this.value, required this.unit});

  final String label;
  final String? value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FittedBox(
          child: Text(
            label,
            style: TextStyle(
              letterSpacing: 1.5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        // Expanded, not a fixed size: the number scales into whatever the band
        // has. A flight instrument should spend spare pixels on the digits.
        Expanded(
          child: FittedBox(
            child: Text(
              value ?? '–',
              style: const TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        if (value != null)
          FittedBox(
            child: Text(unit,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ),
      ],
    );
  }
}

class _InstrumentBand extends StatelessWidget {
  const _InstrumentBand({required this.frame, required this.height});

  final XctodFrame? frame;

  /// Set by the band stack from the viewport, not a constant. See FlightScreen.
  final double height;

  @override
  Widget build(BuildContext context) {
    final f = frame;

    // No reduction band on these dials: the thermal thresholds are
    // user-configurable in the controller's NVS and do not travel over BLE.
    // Drawing the factory 80/100 °C would be showing a number that may not be
    // this pilot's. The full scales below are display ranges only.
    //
    // Only the two temperatures get dials. Power has no maximum, so a circular
    // gauge would have to invent a full scale -- and a needle at 80% of an
    // invented scale reads as a real limit. It is a number.
    return SizedBox(
      height: height,
      child: Row(
      children: [
        Expanded(
          child: Dial(
            label: 'MOTOR',
            value: f?.motorTempC?.toDouble(),
            max: 140,
            unit: '°C',
            badge: switch (f?.motorTempSource) {
              MotorTempSource.can => 'CAN',
              MotorTempSource.ntc => 'NTC',
              _ => null,
            },
          ),
        ),
        Expanded(
          child: Dial(
            label: 'ESC',
            value: f?.escTempC?.toDouble(),
            max: 140,
            unit: '°C',
          ),
        ),
        if (f?.powerKw != null)
          Expanded(
            child: _Readout(
              label: 'POTÊNCIA',
              value: f!.powerKw!.toStringAsFixed(1),
              unit: 'kW',
            ),
          ),
      ],
      ),
    );
  }
}

/// A labelled number with no gauge behind it. For quantities that have no full
/// scale.
///
/// Sized in proportion to the box, with the same ratios as [Dial], so the
/// readout and the dials beside it share one typographic scale. A fixed point
/// size looks fine on the phone it was written on and wraps on a narrower one:
/// at 320 pt across three columns a 38 pt "1.5" broke into two lines and blew
/// the band by 20 px.
class _Readout extends StatelessWidget {
  const _Readout({required this.label, required this.value, required this.unit});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                fontSize: side * 0.10,
                letterSpacing: 1.2,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Flexible(
              child: FittedBox(
                child: Text(
                  value,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: side * 0.30,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            Text(
              unit,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: side * 0.10,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ThrottleBand extends StatelessWidget {
  const _ThrottleBand({required this.frame});

  final XctodFrame? frame;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = frame;
    final pct = f?.throttlePct ?? 0;

    return SizedBox(
      height: 48,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ACELERADOR  ${f == null ? '–' : '$pct %'}',
            style: TextStyle(
              letterSpacing: 1.2,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 18,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom band: opens the secondary readings.
///
/// Six fields arrive in every frame that the panel deliberately does not show
/// -- RPM, state of charge from voltage, the raw throttle ADC value, the BMS
/// maximum temperature and the cell extremes. They were being parsed and
/// thrown away. They belong somewhere reachable, but not on the panel: an
/// overlay is what keeps the BMS connecting or dropping from re-laying out the
/// numbers the pilot is reading.
class _DrawerHandle extends StatelessWidget {
  const _DrawerHandle({required this.frame});

  final XctodFrame? frame;

  @override
  Widget build(BuildContext context) {
    // Fixed height, present even with no frame behind it -- the band stack
    // never changes shape.
    return SizedBox(
      height: 36,
      child: Center(
        child: IconButton(
          tooltip: 'Mais dados',
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: () => showModalBottomSheet(
            context: context,
            showDragHandle: true,
            builder: (_) => _SecondaryData(frame: frame),
          ),
        ),
      ),
    );
  }
}

class _SecondaryData extends StatelessWidget {
  const _SecondaryData({required this.frame});

  final XctodFrame? frame;

  /// An unavailable reading is a dash. Same rule as the panel: the controller
  /// said it has no value, and a zero would read as a measurement.
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
    final f = frame;

    final rows = <(String, String)>[
      ('Carga (por tensão)', f == null ? '–' : '${f.socVoltage} %'),
      ('RPM', _or(f?.rpm, '')),
      ('Acelerador (bruto)', _or(f?.throttleRaw, '')),
      ('Temp. máx. BMS', _or(f?.bmsMaxTempC, ' °C')),
      ('Células mín / máx', _cells),
      ('Origem temp. motor', _source),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      value,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
