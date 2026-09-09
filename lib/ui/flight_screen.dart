import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/xctod_frame.dart';
import 'widgets/dial.dart';

/// The instrument. Purely presentational — it takes a frame and draws it, which
/// is what makes it testable without a radio.
///
/// The band stack is fixed: status, hero, instruments, throttle. Nothing is
/// added or removed at runtime, so an alert can never shift a number the pilot
/// is in the middle of reading.
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
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              _StatusBand(frame: f, stale: stale),
              const SizedBox(height: 12),
              Expanded(flex: 3, child: _HeroBand(frame: f)),
              const SizedBox(height: 12),
              Expanded(flex: 4, child: _InstrumentBand(frame: f)),
              const SizedBox(height: 12),
              _ThrottleBand(frame: f),
            ],
          ),
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
        Text(
          label,
          style: TextStyle(
            letterSpacing: 1.5,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        FittedBox(
          child: Text(
            value ?? '–',
            style: const TextStyle(
              fontSize: 64,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (value != null)
          Text(unit, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _InstrumentBand extends StatelessWidget {
  const _InstrumentBand({required this.frame});

  final XctodFrame? frame;

  @override
  Widget build(BuildContext context) {
    final f = frame;

    // No reduction band on these dials: the thermal thresholds are
    // user-configurable in the controller's NVS and do not travel over BLE.
    // Drawing the factory 80/100 °C would be showing a number that may not be
    // this pilot's. The full scales below are display ranges only.
    return Row(
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
            child: Dial(
              label: 'POTÊNCIA',
              value: f!.powerKw,
              max: 15,
              unit: 'kW',
            ),
          ),
      ],
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
