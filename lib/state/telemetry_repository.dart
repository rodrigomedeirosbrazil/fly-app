import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/fly_controller_link.dart';
import '../protocol/config_groups.dart';
import '../protocol/control_info.dart';
import '../protocol/control_telemetry_codec.dart';
import '../protocol/line_assembler.dart';
import '../protocol/telemetry_frame.dart';
import '../protocol/xctod_parser.dart';
import 'control_session.dart';
import 'link_health.dart';
import 'telemetry_source_policy.dart';

/// Single source of truth for the UI.
///
/// Joins the radio ([FlyControllerLink]) to the pure logic ([LineAssembler],
/// [LinkHealth]) and notifies listeners once per tick.
class TelemetryRepository extends ChangeNotifier {
  TelemetryRepository({
    FlyControllerLink? link,
    LinkHealth? health,
    DateTime Function()? clock,
  })  : _link = link ?? FlyControllerLink(),
        _health = health ?? LinkHealth(),
        _now = clock ?? DateTime.now {
    _statusSub = _link.status.listen(_onStatus);
    _payloadSub = _link.payloads.listen(_onPayload);
    // Staleness has to be re-evaluated even when nothing arrives — that is
    // precisely the case it exists for.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      notifyListeners();
    });
  }

  final FlyControllerLink _link;
  final LinkHealth _health;
  final DateTime Function() _now;
  final LineAssembler _assembler = LineAssembler();

  late final StreamSubscription<LinkStatus> _statusSub;
  late final StreamSubscription<TelemetryPayload> _payloadSub;
  late final Timer _ticker;

  LinkStatus _status = LinkStatus.idle;
  LinkStatus get status => _status;

  /// The frame to render, or null when there is nothing trustworthy to show.
  TelemetryFrame? get frame => _health.frameAt(_now());

  /// True when a frame was received and has since aged out. Distinguishes
  /// "signal lost" from "never connected".
  bool get isStale => _health.isStale(_now());

  int get rejectedFrames => _health.rejectedCount;

  /// Firmware version and controller type, as one support line — `2.4.1 ·
  /// XAG`. Null on the `$XCTOD` path, where INFO was never read.
  ///
  /// Combined into one row rather than two on purpose: the overlay's height
  /// budget in landscape is tight, and these two are always read together.
  String? get firmwareVersion {
    final i = _link.info;
    if (i == null) return null;
    final type = switch (i.controllerType) {
      ControllerType.xag => 'XAG',
      ControllerType.tmotor => 'Tmotor',
      ControllerType.unknown => '?',
    };
    return '${i.appVersion} · $type';
  }

  Future<void> start() async {
    final blocked = await _link.blockingCondition();
    if (blocked != null) {
      // Reported rather than swallowed: a silent no-op button is
      // indistinguishable from a broken one, and Android can refuse a
      // permission permanently, in which case asking again will never show a
      // dialog.
      _status = blocked;
      notifyListeners();
      return;
    }
    await _link.connect();
  }

  Future<void> stop() => _link.disconnect();

  Future<void> openSettings() => _link.openSettings();

  Future<void> openLocationSettings() => _link.openLocationSettings();

  /// True once a decoded frame has reached the UI. After that the telemetry
  /// source is fixed for the connection.
  bool _anyFrameRendered = false;

  ControlSession? _session;

  /// This pilot's configured thermal thresholds, or null when they are not
  /// known: the sentence path, firmware that refuses `CFG_GET`, or a fetch
  /// that never came back.
  ///
  /// Deliberately not cached across connections. The app does not distinguish
  /// one controller from another and the pilot can change these from the web
  /// portal, so a remembered threshold would draw a red band at the wrong
  /// temperature — worse than no band, because a band looks like information.
  ThermalConfig? get thermalConfig => _thermalConfig;
  ThermalConfig? _thermalConfig;

  bool _thermalRequested = false;

  /// Asks for the thermal group once per connection.
  ///
  /// Triggered by the first decoded binary frame rather than by connecting:
  /// at that point the source is settled and the service has demonstrably
  /// produced something.
  ///
  /// Retries only a timeout, and only because `CFG_GET` is a read and
  /// repeating it costs nothing. A refusal or a dropped link stops at once —
  /// there is nothing to wait for. Failure is silent and the dials simply
  /// render as they did before this existed.
  Future<void> _fetchThermalConfig(ControlSession session) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final result = await session.request(
        op: 0x10, // CFG_GET
        payload: [ConfigGroup.thermal.id],
      );

      switch (result) {
        case ControlOk(:final payload):
          _thermalConfig = ThermalConfig.decode(payload);
          notifyListeners();
          return;
        case ControlRefused():
        case ControlDropped():
          return;
        case ControlTimeout():
          break; // breaks the switch; the for loop tries again
      }
    }
  }

  void _onStatus(LinkStatus s) {
    _status = s;
    if (s == LinkStatus.disconnected || s == LinkStatus.idle) {
      // A half-received line cannot be completed across a reconnection, and
      // the next connection re-runs discovery from scratch.
      _assembler.reset();
      _anyFrameRendered = false;
      // Per connection, like the firmware's own auth state. A reply arriving
      // after a reconnect must not reach a request from the previous one.
      _session?.dispose();
      _session = null;
      _thermalRequested = false;
      _thermalConfig = null;
    }
    if (s == LinkStatus.idle) {
      // Only an explicit stop() forgets the last frame. A drop must keep it:
      // isStale is defined by _last surviving, and it is what stops the app
      // from replacing the instrument panel with the connection screen while
      // the pilot is in the air. Nothing stale reaches the UI regardless —
      // frameAt already withholds anything older than staleAfter.
      _health.reset();
    }
    notifyListeners();
  }

  void _onPayload(TelemetryPayload payload) {
    final now = _now();

    switch (payload.source) {
      case TelemetrySource.xctod:
        for (final line in _assembler.add(payload.bytes)) {
          if (_health.onFrame(XctodParser.parse(line, receivedAt: now))) {
            _anyFrameRendered = true;
          }
        }

      case TelemetrySource.control:
        final frame = ControlTelemetryCodec.decode(
          payload.bytes,
          receivedAt: now,
        );
        final decoded = _health.onFrame(frame);

        if (shouldFallBackOnFrame(
          decoded: decoded,
          anyFrameRendered: _anyFrameRendered,
        )) {
          // A struct version this app cannot read fails on the very first
          // frame or never, so nothing on screen changes underneath anyone.
          unawaited(_link.fallBackToXctod());
        }
        if (decoded) {
          _anyFrameRendered = true;
          if (!_thermalRequested && _link.canSendCommands) {
            _thermalRequested = true;
            final session = _session ??= ControlSession(
              _link.sendCommand,
              incoming: _link.responses,
            );
            unawaited(_fetchThermalConfig(session));
          }
        }
    }

    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.cancel();
    _statusSub.cancel();
    _payloadSub.cancel();
    _session?.dispose();
    _link.dispose();
    super.dispose();
  }
}
