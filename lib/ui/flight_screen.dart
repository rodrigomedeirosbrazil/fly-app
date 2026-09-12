import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/config_groups.dart';
import '../protocol/telemetry_frame.dart';
import 'widgets/dial.dart';
import 'widgets/status_chip.dart';

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
  const FlightScreen({
    super.key,
    required this.frame,
    required this.stale,
    this.firmwareVersion,
    this.thermalConfig,
    this.onOpenSettings,
    this.muted = false,
    this.audioError,
    this.onSetMuted,
  });

  final TelemetryFrame? frame;

  /// True when a frame was received but has aged out.
  final bool stale;

  final String? firmwareVersion;

  /// This pilot's configured reduction thresholds, or null when they are not
  /// known. Null draws no band and changes nothing else.
  final ThermalConfig? thermalConfig;

  /// Opens the settings screen. Null when this connection has no request
  /// channel — the `$XCTOD` path, or a controller without the control
  /// service.
  final VoidCallback? onOpenSettings;

  /// Whether the buzzer is muted.
  final bool muted;

  /// What the phone's speaker last refused to do, or null.
  final String? audioError;

  /// Called when the mute state changes.
  final Future<void> Function(bool)? onSetMuted;

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
                    _InstrumentRow(
                      frame: f,
                      thermalConfig: widget.thermalConfig,
                    ),
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
                  firmwareVersion: widget.firmwareVersion,
                  onOpenSettings: widget.onOpenSettings,
                  armed: f?.isArmed ?? false,
                  muted: widget.muted,
                  audioError: widget.audioError,
                  onSetMuted: widget.onSetMuted,
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

  /// `mm:ss`, and minutes keep counting past 60 rather than rolling over — a
  /// paramotor flight is measured in minutes and an hour hand would be one
  /// more thing to read.
  static String _clock(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  /// The short codes the firmware already uses for disarm reasons, so the two
  /// chips in this row speak the same vocabulary.
  static String _causes(Set<LimitCause> causes) => [
    if (causes.contains(LimitCause.battery)) 'BAT',
    if (causes.contains(LimitCause.motorTemp)) 'MOT',
    if (causes.contains(LimitCause.escTemp)) 'ESC',
  ].join(' ');

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
          if (f?.sessionSec != null) ...[
            // Flexible for the same reason the chip beside it is: this row is
            // a fixed height, so anything that cannot shrink overflows hard
            // instead of ellipsizing.
            Flexible(
              child: Text(
                _clock(f!.sessionSec!),
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.onSurfaceVariant,
                  // Tabular figures, so digits do not shuffle every second.
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (f != null && f.isLimited)
            Flexible(
              child: _Chip(
                // Leading with the cause is shorter than the old wording in
                // the single-cause case, which is the common one: the chip
                // gains information and loses width at the same time. A
                // source that cannot say which limiter is acting keeps the
                // original text.
                text: f.limitCauses == null || f.limitCauses!.isEmpty
                    ? 'DISPONÍVEL ${f.powerPct} %'
                    : '${_causes(f.limitCauses!)} ${f.powerPct} %',
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}

/// Kept as a name local to this file; the implementation lives in
/// `widgets/status_chip.dart` so the settings screens use the same one.
class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => StatusChip(text: text, color: color);
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
  /// pack voltage over [kSeriesCells] is a mean dressed up as a minimum, and
  /// says so with a tilde.
  ({String text, String unit})? _perCellReading(TelemetryFrame f) {
    final min = f.cellMinMv;
    if (min != null) {
      return (text: (min / 1000).toStringAsFixed(2), unit: 'V/cél');
    }
    final v = f.voltage;
    if (v == null) return null;
    return (text: '~${(v / kSeriesCells).toStringAsFixed(2)}', unit: 'V/cél');
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
                    width: 1,
                    color: theme.colorScheme.outlineVariant,
                  ),
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
  const _InstrumentRow({required this.frame, this.thermalConfig});

  final TelemetryFrame? frame;
  final ThermalConfig? thermalConfig;

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
                bandStart: thermalConfig?.motorBandStartC,
                bandEnd: thermalConfig?.motorBandEndC,
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
                bandStart: thermalConfig?.escBandStartC,
                bandEnd: thermalConfig?.escBandEndC,
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
  const _Readout({
    required this.label,
    required this.value,
    required this.unit,
  });

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
class _SecondaryData extends StatefulWidget {
  const _SecondaryData({
    required this.frame,
    required this.onClose,
    this.firmwareVersion,
    this.onOpenSettings,
    required this.armed,
    required this.muted,
    this.audioError,
    this.onSetMuted,
  });

  final TelemetryFrame? frame;
  final VoidCallback onClose;
  final String? firmwareVersion;
  final VoidCallback? onOpenSettings;
  final bool armed;
  final bool muted;
  final String? audioError;
  final Future<void> Function(bool)? onSetMuted;

  @override
  State<_SecondaryData> createState() => _SecondaryDataState();
}

class _SecondaryDataState extends State<_SecondaryData> {
  // No local copy of `muted`. The repository owns it and notifies, and
  // app.dart's AnimatedBuilder rebuilds this whole subtree — a second copy
  // here would be free to drift from the one the mirror is actually obeying,
  // which is the failure this codebase refuses everywhere else.
  Future<void> _setMuted(bool value) =>
      widget.onSetMuted?.call(value) ?? Future<void>.value();

  TelemetryFrame? get frame => widget.frame;

  bool get armed => widget.armed;

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

  /// `h:mm:ss`, for counters that run to hundreds of hours.
  static String _hours(Duration? d) {
    if (d == null) return '–';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Sensor health in the pilot's language. Only Valid is a working sensor —
  /// zero is a legitimate reading, so the state is the only thing that
  /// answers this.
  static String _signal(SignalState? s) => switch (s) {
    SignalState.valid => 'OK',
    SignalState.stale => 'PARADO',
    SignalState.invalid => 'INVÁLIDO',
    SignalState.absent => 'AUSENTE',
    null => '–',
  };

  String get _signals {
    final f = frame;
    if (f == null || f.motorTempState == null) return '–';
    return '${_signal(f.motorTempState)} · ${_signal(f.escTempState)}'
        ' · ${_signal(f.batteryVoltageState)}';
  }

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
      ('Horímetro', _hours(f?.hourMeterSec)),
      ('Delta de células', _or(f?.cellDeltaMv, ' mV')),
      ('Sensores (mot · esc · bat)', _signals),
      ('Tempo ligado', _hours(f?.uptimeSec)),
      ('Firmware', widget.firmwareVersion ?? '–'),
    ];

    return Positioned.fill(
      child: GestureDetector(
        onTap: widget.onClose,
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
                          onPressed: widget.onClose,
                        ),
                      ),
                      // Proportional, not a point constant: the sheet's
                      // Container is a Column child and so receives unbounded
                      // height, which is why a plain Flexible cannot bound the
                      // scroll view here. A fixed cap would force scrolling on
                      // a tall phone that has room for every row, and would go
                      // stale as phase 2 adds more of them.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final (label, value) in rows)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 7,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Text(
                                        value,
                                        maxLines: 1,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontFeatures: [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              const SizedBox(height: 8),
                              _MuteControl(
                                key: const Key('mute-buzzer'),
                                muted: widget.muted,
                                audioError: widget.audioError,
                                onSetMuted: _setMuted,
                              ),
                              const SizedBox(height: 8),
                              _SettingsEntry(
                                // Disabled rather than hidden: presence is fixed and
                                // only the state changes, the same rule the status
                                // chips follow. A gate the pilot can see beats an
                                // ErrState arriving after the tap.
                                onTap: armed ? null : widget.onOpenSettings,
                                reason: armed
                                    ? 'Indisponível com a aeronave armada'
                                    : widget.onOpenSettings == null
                                    ? 'Indisponível nesta conexão'
                                    : null,
                              ),
                            ],
                          ),
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

/// The way out of the panel and into settings. The only navigation this app
/// offers from the flight screen, and deliberately behind the drawer the
/// pilot has to open on purpose.
class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({required this.onTap, required this.reason});

  final VoidCallback? onTap;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    final color = enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(Icons.tune, size: 20, color: color),
            const SizedBox(width: 12),
            Text(
              'CONFIGURAÇÕES',
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            if (reason != null)
              Expanded(
                child: Text(
                  reason!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Mute control for the buzzer. Toggles sound on and off.
class _MuteControl extends StatelessWidget {
  const _MuteControl({
    super.key,
    required this.muted,
    required this.onSetMuted,
    this.audioError,
  });

  final bool muted;
  final Future<void> Function(bool)? onSetMuted;

  /// What the speaker last refused to do. Named rather than swallowed: the
  /// pilot is the only one who can tell a silent app from a quiet aircraft,
  /// and this subsystem reached hardware inaudible twice without a word.
  final String? audioError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                muted ? Icons.volume_off : Icons.volume_up,
                size: 20,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'SOM DO CONTROLADOR',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: !muted,
                onChanged: (value) => onSetMuted?.call(!value),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 70,
                child: Text(
                  muted ? 'DESLIGADO' : 'LIGADO',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (audioError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Falha no som: $audioError',
                key: const Key('audio-error'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
