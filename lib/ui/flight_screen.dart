import 'package:flutter/foundation.dart' show kIsWeb;
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
import 'flight/details_view.dart';
import 'flight/flight_drawer.dart';
import 'flight/orientation_lock.dart';
import 'flight/panel_cards.dart';
import 'flight/panel_prefs.dart';
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

class _FlightScreenState extends State<FlightScreen>
    with SingleTickerProviderStateMixin {
  bool _drawerOpen = false;

  /// 0 is the panel, 1 is details fully down. Dragged by the status row.
  late final AnimationController _details = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  bool _pullStartedOpen = false;
  double _height = 1;

  bool _perCell = false;
  bool _showCurrent = false;
  OrientationChoice _orientation = OrientationChoice.portrait;

  final ThermalHysteresis _thermal = ThermalHysteresis();
  TelemetryFrame? _alertsFrame;
  ThermalConfig? _alertsConfig;
  List<FlightAlert> _alerts = const [];

  /// Whether a BMS is configured, as of the last frame that said. FlyApp
  /// hands over a null frame once the link is stale, and reading the flag off
  /// that would flip the bottom row (XAG: no RPM, power or wide voltage) on
  /// signal loss and back on recovery. The row's shape follows the aircraft,
  /// not the link.
  bool _bmsConfigured = false;

  @override
  void initState() {
    super.initState();
    PanelPrefs.load().then((p) {
      if (!mounted) return;
      setState(() {
        _perCell = p.perCell;
        _showCurrent = p.showCurrent;
        _orientation = p.orientation;
      });
      applyOrientation(p.orientation);
    });
  }

  @override
  void dispose() {
    _details.dispose();
    // The connection screen after a disconnect is not locked.
    applyOrientation(OrientationChoice.auto);
    super.dispose();
  }

  void _pullStart(DragStartDetails _) => _pullStartedOpen = _details.value == 1;

  void _pullUpdate(DragUpdateDetails d) =>
      _details.value += (d.primaryDelta ?? 0) / _height;

  /// Opening needs 40 % of the height pulled down; closing needs 40 % pulled
  /// back up. Anything less returns to where it started.
  void _pullEnd(DragEndDetails _) => _settle();

  /// A cancelled drag (the system took the touch) settles by the same rule,
  /// or details would be left stuck part way down.
  void _pullCancel() => _settle();

  void _settle() {
    final open = _pullStartedOpen
        ? _details.value > 1 - kDetailsOpenFraction
        : _details.value >= kDetailsOpenFraction;
    open ? _details.forward() : _details.reverse();
  }

  void _closeDetails() => _details.reverse();

  void _togglePerCell() {
    setState(() => _perCell = !_perCell);
    PanelPrefs.savePerCell(_perCell);
  }

  void _setOrientation(OrientationChoice choice) {
    setState(() => _orientation = choice);
    applyOrientation(choice);
    PanelPrefs.saveOrientation(choice);
  }

  Widget? get _orientationControl => kIsWeb
      ? null
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ORIENTAÇÃO DA TELA',
                style: TextStyle(
                  fontSize: 13,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              SegmentedButton<OrientationChoice>(
                key: const Key('orientation-choice'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: OrientationChoice.portrait,
                    label: Text('Vertical'),
                  ),
                  ButtonSegment(
                    value: OrientationChoice.landscape,
                    label: Text('Horizontal'),
                  ),
                  ButtonSegment(
                    value: OrientationChoice.auto,
                    label: Text('Automático'),
                  ),
                ],
                selected: {_orientation},
                onSelectionChanged: (s) => _setOrientation(s.first),
              ),
            ],
          ),
        );

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

  /// Everything that says how much flying is left on the left; the portrait
  /// cards in their portrait order on the right, so the pilot's map transfers.
  Widget _landscape(
    BuildContext context,
    TelemetryFrame? f,
    List<FlightAlert> alerts,
  ) {
    const gap = SizedBox(height: 8);
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    _statusRow(context, f),
                    gap,
                    Expanded(child: BatteryGaugeCard(frame: f)),
                    gap,
                    FlightTimesRow(frame: f),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    Expanded(
                      child: _thermalRow(f, alerts, widget.thermalConfig),
                    ),
                    gap,
                    Expanded(child: _bottomRow(f)),
                    gap,
                    ThrottleCard(frame: f),
                  ],
                ),
              ),
            ],
          ),
        ),
        gap,
        _DrawerBar(onTap: _openDrawer, alerts: alerts, hasFrame: f != null),
      ],
    );
  }

  Widget _statusRow(BuildContext context, TelemetryFrame? f) => _StatusRow(
    frame: f,
    stale: widget.stale,
    reconnecting: _reconnecting,
    onTap: widget.onDisconnect == null ? null : () => _confirmLink(context),
    onPullStart: _pullStart,
    onPullUpdate: _pullUpdate,
    onPullEnd: _pullEnd,
    onPullCancel: _pullCancel,
  );

  /// `disconnected` is the wait between two attempts: the link reports it
  /// and then schedules the retry.
  bool get _reconnecting => const {
    LinkStatus.scanning,
    LinkStatus.connecting,
    LinkStatus.disconnected,
  }.contains(widget.linkStatus);

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

  Widget _bottomRow(TelemetryFrame? f) {
    final configured = f?.bmsConfigured;
    if (configured != null) _bmsConfigured = configured;
    return BottomRowCards(
      layout: bottomRowFor(
        type: widget.controllerType,
        bmsConfigured: _bmsConfigured,
      ),
      frame: f,
      powerConfig: widget.powerConfig,
      perCell: _perCell,
      showCurrent: _showCurrent,
      onTogglePerCell: _togglePerCell,
      onToggleCurrent: _toggleCurrent,
    );
  }

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
        if (_details.value > 0) {
          _closeDetails();
        } else if (_drawerOpen) {
          setState(() => _drawerOpen = false);
        }
      },
      child: Scaffold(
        body: SafeArea(
          // The pull is a fraction of the visible height, so it is measured
          // here, inside the safe area.
          child: LayoutBuilder(
            builder: (context, c) {
              _height = c.maxHeight;
              final wide = c.maxWidth > c.maxHeight;
              return Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                    child: wide
                        ? _landscape(context, f, alerts)
                        : _portrait(context, f, alerts),
                  ),
                  // In the tree, not a pushed route. A modal route builds once
                  // from the frame captured when it opened and never sees
                  // another, so its alerts would silently freeze at 1 Hz.
                  if (_drawerOpen)
                    FlightDrawer(
                      alerts: alerts,
                      hasFrame: f != null,
                      muted: widget.muted,
                      audioError: widget.audioError,
                      onSetMuted: widget.onSetMuted,
                      armed: f?.isArmed ?? false,
                      onOpenSettings: widget.onOpenSettings,
                      onClose: () => setState(() => _drawerOpen = false),
                      orientationControl: _orientationControl,
                      leftInset: wide ? c.maxWidth * 0.4 : 0,
                    ),
                  // Details, for the same reason: in the tree, so every frame
                  // reaches it. Slid down from above by the controller the
                  // status row drives.
                  AnimatedBuilder(
                    animation: _details,
                    builder: (context, _) => _details.value == 0
                        ? const SizedBox.shrink()
                        : Positioned.fill(
                            child: Transform.translate(
                              offset: Offset(
                                0,
                                -_height * (1 - _details.value),
                              ),
                              child: DetailsView(
                                frame: f,
                                stale: widget.stale,
                                reconnecting: _reconnecting,
                                alerts: alerts,
                                thermalConfig: widget.thermalConfig,
                                controllerType: widget.controllerType,
                                columns: wide ? 2 : 1,
                                telemetrySource: widget.telemetrySource,
                                rejectedFrames: widget.rejectedFrames,
                                firmwareVersion: widget.firmwareVersion,
                                firmwareBuild: widget.firmwareBuild,
                                onClose: _closeDetails,
                                onHandleDragUpdate: (d) {
                                  _pullStartedOpen = true;
                                  _pullUpdate(d);
                                },
                                onHandleDragEnd: _pullEnd,
                                onHandleDragCancel: () {
                                  _pullStartedOpen = true;
                                  _pullCancel();
                                },
                              ),
                            ),
                          ),
                  ),
                ],
              );
            },
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
    this.onPullStart,
    this.onPullUpdate,
    this.onPullEnd,
    this.onPullCancel,
  });

  final TelemetryFrame? frame;
  final bool stale;

  /// The link is retrying. Only shown while stale: a live frame says more.
  final bool reconnecting;

  /// Opens the reconnect / disconnect confirmation.
  final VoidCallback? onTap;

  /// The row is the handle for pulling details down. A tap on the chip and a
  /// vertical drag anywhere on the row resolve in the gesture arena.
  final GestureDragStartCallback? onPullStart;
  final GestureDragUpdateCallback? onPullUpdate;
  final GestureDragEndCallback? onPullEnd;
  final GestureDragCancelCallback? onPullCancel;

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
    return GestureDetector(
      key: const Key('details-handle'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: onPullStart,
      onVerticalDragUpdate: onPullUpdate,
      onVerticalDragEnd: onPullEnd,
      onVerticalDragCancel: onPullCancel,
      child: SizedBox(
        height: 30,
        child: Stack(
          children: [
            Row(
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
                // _confirmLink. A plain GestureDetector keeps the fixed row
                // height.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: _Chip(text: chip.text, color: chip.color),
                ),
                const Spacer(),
              ],
            ),
            // The handle: the only sign the row can be pulled.
            // Ignoring pointers: the bar lies over the chip on a narrow phone
            // and must not take its taps. Drags still reach the row.
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outline,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ],
        ),
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
