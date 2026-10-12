import 'package:flutter/material.dart';

import '../ble/fly_controller_link.dart';
import '../protocol/config_groups.dart';
import '../protocol/control_info.dart';
import '../protocol/telemetry_frame.dart';
import '../state/flight_alerts.dart';
import '../state/gauge_levels.dart';
import '../state/panel_layout_policy.dart';
import '../state/telemetry_source_policy.dart';
import 'flight/alert_card.dart';
import 'flight/panel_cards.dart';
import 'flight/panel_prefs.dart';
import 'reading_text.dart';
import 'widgets/status_chip.dart';

/// The instrument, portrait.
///
/// Fixed order, fixed presence: status row, battery arc, flight times, the
/// alert card beside the motor and ESC temperatures, throttle, then voltage,
/// power or current, and RPM, and the drawer bar. Nothing is added to or
/// removed from that stack at runtime, so an alert can never shift a number
/// the pilot is in the middle of reading — a fault shows as a chip in space
/// the status row already reserves, a limiter as a line on the alert card.
///
/// Every gauge is an arc whose colour is its whole state, from
/// `gauge_levels.dart`. Which cards the bottom row carries is decided by the
/// board and the BMS configuration, never by what the last frame lacked, so
/// a reading that disappears in use keeps its card and shows its reason.
///
class FlightScreen extends StatefulWidget {
  const FlightScreen({
    super.key,
    required this.frame,
    required this.stale,
    this.firmwareVersion,
    this.firmwareBuild,
    this.thermalConfig,
    this.onOpenSettings,
    this.muted = false,
    this.audioError,
    this.onSetMuted,
    this.linkStatus,
    this.lastFrameAt,
    this.lastFrameArmed = false,
    this.now,
    this.onReconnect,
    this.onDisconnect,
    this.controllerType = ControllerType.unknown,
    this.powerConfig,
    this.telemetrySource,
    this.rejectedFrames = 0,
  });

  final TelemetryFrame? frame;

  /// What the radio is doing. Lets the status chip tell "trying" from
  /// "given up" while the panel is stale.
  final LinkStatus? linkStatus;

  /// When the last frame arrived, however old, and whether it said armed.
  /// For the disconnect confirmation only.
  final DateTime? lastFrameAt;
  final bool lastFrameArmed;

  /// The clock [lastFrameAt] is measured against. Null uses the wall clock.
  final DateTime Function()? now;

  /// Tries the link again without leaving this screen.
  final VoidCallback? onReconnect;

  /// Stops the link and returns to the connection screen.
  final VoidCallback? onDisconnect;

  /// True when a frame was received but has aged out.
  final bool stale;

  final String? firmwareVersion;

  /// When that firmware was built. Null on controllers that do not send it.
  final String? firmwareBuild;

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

  /// The board, from `INFO`. Picks the bottom row and the ESC temperature
  /// source. Unknown on the `$XCTOD` path.
  final ControllerType controllerType;

  /// The pilot's voltage window. Null draws the voltage with no arc.
  final PowerConfig? powerConfig;

  /// For the details screen.
  final TelemetrySource? telemetrySource;
  final int rejectedFrames;

  @override
  State<FlightScreen> createState() => _FlightScreenState();
}

enum _LinkAction { reconnect, disconnect }

class _FlightScreenState extends State<FlightScreen> {
  bool _drawerOpen = false;

  bool _perCell = false;
  bool _showCurrent = false;

  final ThermalHysteresis _thermal = ThermalHysteresis();
  TelemetryFrame? _alertsFrame;
  ThermalConfig? _alertsConfig;
  List<FlightAlert> _alerts = const [];

  @override
  void initState() {
    super.initState();
    PanelPrefs.load().then((p) {
      if (!mounted) return;
      setState(() {
        _perCell = p.perCell;
        _showCurrent = p.showCurrent;
      });
    });
  }

  void _togglePerCell() {
    setState(() => _perCell = !_perCell);
    PanelPrefs.savePerCell(_perCell);
  }

  void _toggleCurrent() {
    setState(() => _showCurrent = !_showCurrent);
    PanelPrefs.saveShowCurrent(_showCurrent);
  }

  /// Recomputed once per new frame or new thermal config, not per build: the
  /// repository notifies for reasons other than telemetry, and the hysteresis
  /// must advance once per frame. The config arrives a moment after the first
  /// frame, so a change of it recomputes too, or thermal alerts would lag a
  /// frame behind it.
  ///
  /// Mutating [_thermal] from a getter that build calls is acceptable here
  /// because it is idempotent per input: applying the same frame and config
  /// again leaves the levels where they are.
  List<FlightAlert> get alerts {
    final f = widget.frame;
    if (f == null) return const [];
    if (!identical(f, _alertsFrame) ||
        !identical(widget.thermalConfig, _alertsConfig)) {
      _alertsFrame = f;
      _alertsConfig = widget.thermalConfig;
      _thermal.update(f, widget.thermalConfig);
      _alerts = flightAlerts(
        f,
        motorLevel: _thermal.motor,
        escLevel: _thermal.esc,
        thermal: widget.thermalConfig,
      );
    }
    return _alerts;
  }

  /// The only way off this screen. Never automatic — replacing the panel in
  /// flight is the one thing it must not do on its own — so it is the
  /// pilot's, behind a confirmation a stray tap cannot get through.
  void _confirmLink(BuildContext context) {
    final at = widget.lastFrameAt;
    final silentFor = (widget.stale && at != null)
        ? (widget.now ?? DateTime.now)().difference(at).inSeconds
        : null;

    showDialog<_LinkAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          widget.stale
              ? 'Sem dados do controlador'
              : 'Desconectar do controlador?',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (silentFor != null) Text('Último dado há $silentFor s.'),
            if (widget.lastFrameArmed) ...[
              if (silentFor != null) const SizedBox(height: 12),
              const Text(
                'O último dado dizia ARMADO. Desconectar o app não desliga o '
                'motor, mas o painel sai da tela.',
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _LinkAction.disconnect),
            child: const Text('Desconectar'),
          ),
          if (widget.stale && widget.onReconnect != null)
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _LinkAction.reconnect),
              child: const Text('Reconectar'),
            ),
        ],
      ),
    ).then((action) {
      switch (action) {
        case _LinkAction.reconnect:
          widget.onReconnect?.call();
        case _LinkAction.disconnect:
          widget.onDisconnect?.call();
        case null:
          break;
      }
    });
  }

  void _openDrawer() => setState(() => _drawerOpen = true);

  /// Fixed order, fixed presence: status, battery, flight times, alerts beside
  /// the two temperatures, throttle, bottom row, drawer bar.
  Widget _portrait(
    BuildContext context,
    TelemetryFrame? f,
    List<FlightAlert> alerts,
  ) {
    const gap = SizedBox(height: 8);
    final thermal = widget.thermalConfig;
    return Column(
      children: [
        _statusRow(context, f),
        gap,
        Expanded(flex: 5, child: BatteryGaugeCard(frame: f)),
        gap,
        FlightTimesRow(frame: f),
        gap,
        Expanded(flex: 3, child: _thermalRow(f, alerts, thermal)),
        gap,
        ThrottleCard(frame: f),
        gap,
        Expanded(flex: 3, child: _bottomRow(f)),
        gap,
        _DrawerBar(onTap: _openDrawer, alerts: alerts, hasFrame: f != null),
      ],
    );
  }

  Widget _statusRow(BuildContext context, TelemetryFrame? f) => _StatusRow(
    frame: f,
    stale: widget.stale,
    // `disconnected` is the wait between two attempts: the link reports it
    // and then schedules the retry.
    reconnecting: const {
      LinkStatus.scanning,
      LinkStatus.connecting,
      LinkStatus.disconnected,
    }.contains(widget.linkStatus),
    onTap: widget.onDisconnect == null ? null : () => _confirmLink(context),
  );

  Widget _thermalRow(
    TelemetryFrame? f,
    List<FlightAlert> alerts,
    ThermalConfig? thermal,
  ) {
    const gap = SizedBox(width: 8);
    return Row(
      children: [
        Expanded(
          child: AlertCard(
            alerts: alerts,
            hasFrame: f != null,
            onTap: _openDrawer,
          ),
        ),
        gap,
        Expanded(
          child: TemperatureGauge(
            dialKey: const Key('gauge-motor'),
            caption: 'TEMP MOTOR',
            value: f?.motorTempC,
            state: f?.motorTempState,
            badge: switch (f?.motorTempSource) {
              MotorTempSource.can => 'CAN',
              MotorTempSource.ntc => 'NTC',
              _ => null,
            },
            start: thermal?.motorBandStartC,
            end: thermal?.motorBandEndC,
            level: _thermal.motor,
          ),
        ),
        gap,
        Expanded(
          child: TemperatureGauge(
            dialKey: const Key('gauge-esc'),
            caption: 'TEMP ESC',
            value: f?.escTempC,
            state: f?.escTempState,
            // A missing reading carries no provenance, same as the motor.
            badge: f?.escTempC == null
                ? null
                : escTempSourceFor(widget.controllerType),
            start: thermal?.escBandStartC,
            end: thermal?.escBandEndC,
            level: _thermal.esc,
          ),
        ),
      ],
    );
  }

  Widget _bottomRow(TelemetryFrame? f) => BottomRowCards(
    layout: bottomRowFor(
      type: widget.controllerType,
      bmsConfigured: f?.bmsConfigured ?? false,
    ),
    frame: f,
    powerConfig: widget.powerConfig,
    perCell: _perCell,
    showCurrent: _showCurrent,
    onTogglePerCell: _togglePerCell,
    onToggleCurrent: _toggleCurrent,
  );

  @override
  Widget build(BuildContext context) {
    final f = widget.frame;
    final alerts = this.alerts;

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
                child: _portrait(context, f, alerts),
              ),
              // In the tree, not a pushed route. A modal route builds once
              // from the frame captured when it opened and never sees
              // another, so the readings behind it silently freeze at 1 Hz.
              if (_drawerOpen)
                _SecondaryData(
                  frame: f,
                  onClose: () => setState(() => _drawerOpen = false),
                  firmwareVersion: widget.firmwareVersion,
                  firmwareBuild: widget.firmwareBuild,
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

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.frame,
    required this.stale,
    this.reconnecting = false,
    this.onTap,
  });

  final TelemetryFrame? frame;
  final bool stale;

  /// The link is retrying. Only shown while stale: a live frame says more.
  final bool reconnecting;

  /// Opens the reconnect / disconnect confirmation.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = frame;

    final chip = statusChipFor(
      theme.colorScheme,
      f,
      stale: stale,
      reconnecting: reconnecting,
    );

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
          // The chip is the handle for leaving this screen; see
          // _confirmLink. A plain GestureDetector keeps the fixed row height.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: _Chip(text: chip.text, color: chip.color),
          ),
          const Spacer(),
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

/// Bottom bar. Names what is behind it, and how many alerts wait there.
class _DrawerBar extends StatelessWidget {
  const _DrawerBar({
    required this.onTap,
    required this.alerts,
    required this.hasFrame,
  });

  final VoidCallback onTap;
  final List<FlightAlert> alerts;
  final bool hasFrame;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = hasFrame ? alerts.length : 0;
    final accent = n == 0
        ? null
        : alertStyle(theme.colorScheme, alerts.first.severity).accent;
    final style = TextStyle(
      fontSize: 12,
      letterSpacing: 1.5,
      fontWeight: FontWeight.w700,
      color: theme.colorScheme.onSurface,
    );
    return Tooltip(
      message: 'Configurações e alertas',
      child: PanelCard(
        key: const Key('drawer-bar'),
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.keyboard_arrow_up, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text.rich(
                TextSpan(
                  text: 'CONFIGURAÇÕES',
                  children: [
                    if (n > 0)
                      TextSpan(
                        text: ' · $n ${n == 1 ? 'ALERTA' : 'ALERTAS'}',
                        style: TextStyle(color: accent),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ],
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
    this.firmwareBuild,
    this.onOpenSettings,
    required this.armed,
    required this.muted,
    this.audioError,
    this.onSetMuted,
  });

  final TelemetryFrame? frame;
  final VoidCallback onClose;
  final String? firmwareVersion;

  /// When that firmware was built. Null on controllers that do not send it.
  final String? firmwareBuild;
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

  /// Where the per-cell figure on the voltage card comes from. The card only
  /// shows a tilde for the computed one; the portal names both.
  String get _cellSource {
    final f = frame;
    if (f == null) return '–';
    if (f.cellMinMv != null) return 'BMS · menor célula';
    if (f.voltage != null) return 'Calculado ÷${kSeriesCells}S';
    return '–';
  }

  /// From the frame's flags. Null on the sentence path, which carries none.
  String get _bmsState {
    final f = frame;
    // The link state tells connecting from disconnected, which the two flags
    // below cannot; they remain for firmware that predates it.
    switch (f?.bmsLinkState) {
      case BmsLinkState.connected:
        return 'Conectado';
      case BmsLinkState.connecting:
        return 'Conectando';
      case BmsLinkState.idle:
        return 'Ocioso';
      case BmsLinkState.notConfigured:
        return 'Não configurado';
      case BmsLinkState.unknown:
      case null:
        break;
    }
    if (f?.bmsConnected == true) return 'Conectado';
    if (f?.bmsConfigured == true) return 'Sem conexão';
    if (f?.bmsConfigured == false) return 'Não configurado';
    return '–';
  }

  /// `h:mm:ss`, for counters that run to hundreds of hours.
  static String _hours(Duration? d) {
    if (d == null) return '–';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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
      // Beside the two numbers it is derived from, not four rows away.
      ('Delta de células', _or(f?.cellDeltaMv, ' mV')),
      ('Tensão por célula', _cellSource),
      ('BMS', _bmsState),
      ('Origem temp. motor', _source),
      ('Horímetro', _hours(f?.hourMeterSec)),
      ('Tempo ligado', _hours(f?.uptimeSec)),
      ('Firmware', widget.firmwareVersion ?? '–'),
      // Hidden rather than dashed: on firmware that predates the field this
      // is a reading that does not exist, and an empty row beside a version
      // that did load reads as a failure to fetch it.
      if (widget.firmwareBuild != null) ('Build', widget.firmwareBuild!),
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
                              if (f != null && f.disarmCode != null)
                                _FaultExplanation(
                                  key: const Key('fault-explanation'),
                                  // A reason newer firmware sent has no
                                  // sentence here; the portal falls back to
                                  // the bare code rather than saying nothing.
                                  text:
                                      kFaultExplanations[f.disarmReason] ??
                                      (
                                        title: 'Desarmado por falha',
                                        detail: 'Código: ${f.disarmCode}',
                                      ),
                                ),
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
                                key: const Key('settings-entry'),
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
  const _SettingsEntry({super.key, required this.onTap, required this.reason});

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

/// The latched fault, in words. The status row has room for the code only;
/// this is the sentence behind it, one tap away, as on the portal.
class _FaultExplanation extends StatelessWidget {
  const _FaultExplanation({super.key, required this.text});

  final ({String title, String detail}) text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text.title,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            text.detail,
            style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface),
          ),
        ],
      ),
    );
  }
}
