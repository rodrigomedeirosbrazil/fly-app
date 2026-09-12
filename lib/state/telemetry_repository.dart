import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/tone_player.dart';
import '../ble/fly_controller_link.dart';
import '../protocol/beep_event.dart';
import '../protocol/config_groups.dart';
import '../protocol/control_frame.dart';
import '../protocol/control_info.dart';
import '../protocol/control_telemetry_codec.dart';
import '../protocol/line_assembler.dart';
import '../protocol/telemetry_frame.dart';
import '../protocol/xctod_parser.dart';
import 'buzzer_mirror.dart';
import 'config_editor.dart';
import 'control_session.dart';
import 'dfu_session.dart';
import 'link_health.dart';
import 'telemetry_source_policy.dart';

/// Concrete implementation of [DfuTransport] wired to a link and session.
class _DfuTransportImpl implements DfuTransport {
  _DfuTransportImpl(this._session, this._link, this._editor);

  final ControlSession _session;
  final FlyControllerLink _link;

  /// The connection's editor, so the PIN typed to save a setting also covers
  /// a firmware update. The firmware authenticates per connection; two flags
  /// here would mean two prompts.
  final ConfigEditor _editor;

  @override
  Future<bool> authenticate(String pin) async =>
      await _editor.authenticate(pin) == null;

  @override
  Future<ControlResult> request({required int op, List<int> payload = const []}) =>
      _session.request(op: op, payload: payload);

  @override
  Future<void> writeData(List<int> bytes) => _link.writeDfuData(bytes);

  @override
  int get maxWriteBytes => _link.maxDfuWriteBytes;
}

/// Single source of truth for the UI.
///
/// Joins the radio ([FlyControllerLink]) to the pure logic ([LineAssembler],
/// [LinkHealth]) and notifies listeners once per tick.
class TelemetryRepository extends ChangeNotifier {
  TelemetryRepository({
    FlyControllerLink? link,
    LinkHealth? health,
    DateTime Function()? clock,
    BuzzerMirror? mirror,
  })  :
        // prefer_initializing_formals suggests `this._mirror`, which does not
        // compile: a named parameter cannot carry a private name. Same
        // situation as ControlSession's `_send`.
        // ignore: prefer_initializing_formals
        _mirror = mirror,
        _link = link ?? FlyControllerLink(),
        _health = health ?? LinkHealth(),
        _now = clock ?? DateTime.now {
    // Built here rather than in the initialiser list so the player can report
    // failures back: a beep that fails silently is indistinguishable from a
    // controller with nothing to say, which is how this subsystem reached
    // hardware inaudible twice.
    _mirror ??= BuzzerMirror(AudioPlayersTonePlayer(onError: _onAudioError));

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
  BuzzerMirror? _mirror;

  /// What the speaker last refused to do, or null. Shown in the drawer beside
  /// the sound control, because the pilot is the only one who can tell a
  /// silent app from a quiet aircraft.
  String? get audioError => _audioError;
  String? _audioError;

  void _onAudioError(Object error) {
    _audioError = error.toString();
    notifyListeners();
  }
  final LineAssembler _assembler = LineAssembler();

  late final StreamSubscription<LinkStatus> _statusSub;
  late final StreamSubscription<TelemetryPayload> _payloadSub;
  late final Timer _ticker;
  StreamSubscription<ControlResponse>? _eventsSub;

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
    // An empty `appVersion` would render as " · Tmotor" — a line that opens
    // with a separator and looks like a rendering fault rather than a missing
    // reading. The field is `char[24]` NUL-*padded*, so a firmware that never
    // filled it decodes to the empty string rather than to null.
    if (i.appVersion.isEmpty) return type;
    return '${i.appVersion} · $type';
  }

  /// When the running firmware was built — `Sep 12 2026 12:46:03` — or null.
  ///
  /// **Null on every controller built before the field existed**, because it
  /// rides on the end of `INFO` under the append rule. That is a missing
  /// reading, not a fault, and the row hides rather than printing a dash that
  /// looks like a date failed to load.
  ///
  /// `APP_VERSION` alone does not answer "is this the build I just flashed?":
  /// CI stamps it with the release tag and every local build reports `dev`,
  /// so two different images a week apart carry the same version string. The
  /// portal shows the build stamp beside the version for exactly this reason.
  String? get firmwareBuild {
    final i = _link.info;
    if (i == null || i.buildDate == null) return null;
    final time = i.buildTime;
    return time == null ? i.buildDate : '${i.buildDate} $time';
  }

  /// The live request channel, or null on the `$XCTOD` path.
  ControlSession? get session => _session;

  /// The one editor for this connection, or null on the `$XCTOD` path.
  ///
  /// **One per connection, not one per screen.** `ConfigEditor` carries the
  /// authenticated flag, and the firmware clears its own `authenticated_` in
  /// `onCentralDisconnected()` — so the connection is the unit the PIN
  /// belongs to on both sides. Building an editor per route made every screen,
  /// and even the scan and the save button on the *same* screen, hold a
  /// separate flag: the pilot was asked for the PIN again on each one.
  ConfigEditor? get editor => _editor;

  /// The transport for DFU transfers, or null when the DFU characteristic is
  /// absent. A controller without it simply does not support firmware updates
  /// over BLE, and everything else keeps working.
  DfuTransport? get dfuTransport => _dfuTransport;
  DfuTransport? _dfuTransport;

  /// Whether the buzzer is muted.
  bool get muted => _mirror?.muted ?? false;

  /// Mute or unmute the buzzer.
  Future<void> setMuted(bool value) async {
    await _mirror!.setMuted(value);
    notifyListeners();
    // Turning sound on answers "does this work?" immediately, rather than
    // leaving the pilot to arm the aircraft to find out.
    if (!value) _audioError = null;
      await _mirror!.confirmAudible();
  }

  /// Whether the controller reports a selectable motor temperature source.
  /// False when INFO was never read.
  bool get selectableMotorTempSource =>
      _link.info?.hasSelectableMotorTempSource ?? false;

  /// Whether the controller supports remote pairing. False when INFO was never
  /// read.
  bool get hasRemoteLink => _link.info?.hasRemoteLink ?? false;

  /// Whether the controller supports firmware updates over BLE.
  /// False when INFO was never read or the DFU characteristic is absent.
  bool get canUpdateFirmware => _link.canUpdateFirmware;

  /// The `Power` group, fetched alongside the thermal one.
  PowerConfig? get powerConfig => _powerConfig;
  PowerConfig? _powerConfig;

  /// The `Bms` group, fetched after the power one.
  BmsConfig? get bmsConfig => _bmsConfig;
  BmsConfig? _bmsConfig;

  /// The `System` group, fetched after the BMS one.
  SystemConfig? get systemConfig => _systemConfig;
  SystemConfig? _systemConfig;

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
  ConfigEditor? _editor;

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

  /// Requests a config group with retry on timeout.
  ///
  /// Retries only a timeout, and only because `CFG_GET` is a read and
  /// repeating it costs nothing. A refusal or a dropped link stops at once —
  /// there is nothing to wait for. Returns null on any failure.
  /// Returns the controller's answer, whatever it was.
  ///
  /// The result rather than the bytes, because the caller has to tell a
  /// refusal apart from silence: `CFG_GET` is a single opcode with the group
  /// as a payload byte, so `ErrBadOp` means this firmware has no `CFG_GET` at
  /// all and asking for the other group would get the same answer.
  Future<ControlResult> _requestGroup(
    ControlSession session,
    ConfigGroup group,
  ) async {
    ControlResult result = const ControlTimeout();
    for (var attempt = 0; attempt < 3; attempt++) {
      result = await session.request(
        op: 0x10, // CFG_GET
        payload: [group.id],
      );
      if (result is! ControlTimeout) return result;
    }
    return result;
  }

  /// Asks for all four config groups once per connection.
  ///
  /// Triggered by the first decoded binary frame rather than by connecting:
  /// at that point the source is settled and the service has demonstrably
  /// produced something.
  ///
  /// Failure is silent and the dials simply render as they did before this
  /// existed.
  Future<void> _fetchConfig(ControlSession session) async {
    final thermal = await _requestGroup(session, ConfigGroup.thermal);
    if (thermal is ControlOk) {
      _thermalConfig = ThermalConfig.decode(thermal.payload);
      notifyListeners();
    } else if (thermal is ControlRefused &&
        thermal.status == ControlStatus.errBadOp) {
      // This firmware does not have CFG_GET. The group is only a payload
      // byte, so the Power request would be refused identically -- and on a
      // controller that never answers, skipping it halves the traffic spent
      // finding that out.
      return;
    }

    final power = await _requestGroup(session, ConfigGroup.power);
    if (power is ControlOk) {
      _powerConfig = PowerConfig.decode(power.payload);
      notifyListeners();
    }

    final bms = await _requestGroup(session, ConfigGroup.bms);
    if (bms is ControlOk) {
      _bmsConfig = BmsConfig.decode(bms.payload);
      notifyListeners();
    }

    final system = await _requestGroup(session, ConfigGroup.system);
    if (system is ControlOk) {
      _systemConfig = SystemConfig.decode(system.payload);
      notifyListeners();
    }
  }

  /// Takes what the controller reported after a write.
  ///
  /// The re-read is the authority, not the values the app sent — the same
  /// rule `_fetchConfig` follows. Without this the cache stayed at whatever
  /// the connection opened with, so a saved threshold was invisible until the
  /// next reconnect and the dials kept their old band.
  void _applyGroupRead(SaveOk read) {
    if (read.thermal != null) _thermalConfig = read.thermal;
    if (read.power != null) _powerConfig = read.power;
    if (read.bms != null) _bmsConfig = read.bms;
    if (read.system != null) _systemConfig = read.system;
    notifyListeners();
  }

  /// Unsolicited `RSP` frames. Only `EVT_BEEP` means anything to this app so
  /// far; anything else is ignored rather than logged, because newer firmware
  /// is allowed to send events this build has never heard of.
  void _onEvent(ControlResponse response) {
    if (response.op != kOpEvtBeep) return;
    final beep = BeepEvent.decode(response.payload);
    if (beep == null) return;
    unawaited(_mirror!.handle(beep));
  }

  /// Sweeps the mirrored gesture tone with the aircraft's own scalar.
  ///
  /// The firmware pushes a beep event when a state *starts* and never when it
  /// retunes, so the mirror would hold the base 1800 Hz for an arm charge the
  /// pilot hears climbing. The scalars are in every frame; the arithmetic is
  /// the firmware's, in `buzzer_mirror.dart`.
  void _retuneGesture() {
    final f = frame;
    if (f == null) return;
    unawaited(_mirror!.retuneState(gestureFrequencyFor(
      isArmed: f.isArmed,
      armCharge: f.armCharge,
      powerScale: f.powerScale,
    )));
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
      // With the session, because the PIN it holds is per connection.
      _editor = null;
      _dfuTransport = null;
      _eventsSub?.cancel();
      _eventsSub = null;
      _thermalRequested = false;
      _thermalConfig = null;
      _powerConfig = null;
      _bmsConfig = null;
      _systemConfig = null;
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
          _retuneGesture();
          if (!_thermalRequested && _link.canSendCommands) {
            _thermalRequested = true;
            final session = _session ??= ControlSession(
              _link.sendCommand,
              incoming: _link.responses,
            );
            _eventsSub ??= session.events.listen(_onEvent);
            _editor ??= ConfigEditor(session, onGroupRead: _applyGroupRead);
            // DFU transport is available when the characteristic exists
            _dfuTransport ??= _link.canUpdateFirmware
                ? _DfuTransportImpl(session, _link, _editor!)
                : null;
            unawaited(_fetchConfig(session));
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
    _eventsSub?.cancel();
    _session?.dispose();
    _mirror?.dispose();
    _link.dispose();
    super.dispose();
  }
}
