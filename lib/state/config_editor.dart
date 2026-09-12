import 'dart:typed_data';

import '../protocol/bms_scan.dart';
import '../protocol/config_groups.dart';
import '../protocol/control_frame.dart';
import 'control_session.dart';

const int _opAuth = 0x01;
const int _opCfgGet = 0x10;
const int _opCfgSet = 0x11;
const int _opBmsScanStart = 0x21;
const int _opBmsScanStatus = 0x22;
const int _opRemotePair = 0x24;
const int _opRemoteForget = 0x25;
const int _opBuzzerPreview = 0x26;

/// How many times an idempotent request is resent after a timeout.
const int _attempts = 3;

/// What happened to a save.
sealed class SaveOutcome {
  const SaveOutcome();
}

/// Written. [power] or [thermal] carries what the controller reported when
/// asked again, or null when that confirmation did not come back.
class SaveOk extends SaveOutcome {
  const SaveOk({this.power, this.thermal, this.bms, this.system});
  final PowerConfig? power;
  final ThermalConfig? thermal;
  final BmsConfig? bms;
  final SystemConfig? system;
}

/// No authenticated session. Prompt, then call again with a PIN.
class SaveNeedsPin extends SaveOutcome {
  const SaveNeedsPin({this.sessionLost = false});

  /// True when the connection *had* authenticated and the controller has
  /// since forgotten it — `ErrAuth` on a request that should have passed.
  ///
  /// Worth telling apart, because the two feel completely different to a
  /// pilot. The first prompt of a connection is expected. A second one, after
  /// saving something a minute ago, looks like the app losing the PIN — so it
  /// says that the controller dropped the session instead of asking again in
  /// silence.
  final bool sessionLost;
}

/// The PIN was wrong. The firmware has already cleared the session, so there
/// is nothing left to preserve — asking again is the only move.
class SaveWrongPin extends SaveOutcome {
  const SaveWrongPin();
}

/// Refused because the aircraft is armed. **Never prompt for a PIN in
/// response to this**: `gateRequest()` reports armed before auth precisely so
/// a client does not ask for a password to do something refused either way.
class SaveRefusedArmed extends SaveOutcome {
  const SaveRefusedArmed();
}

/// The controller rejected a value this app's validation accepted.
///
/// Not a pilot error, and it must not be shown as one: it means
/// `settings_validation.dart` has drifted from the firmware's
/// `SettingsValidation.h`. That drift has no other detector.
class SaveRejectedByController extends SaveOutcome {
  const SaveRejectedByController();
}

/// Firmware too old to accept this write at all.
class SaveUnsupported extends SaveOutcome {
  const SaveUnsupported();
}

/// The controller is already doing this. Only `BMS_SCAN_START` produces it:
/// the scanner is a single resource, and a second start would be a second
/// answer to a question already being asked.
class SaveBusy extends SaveOutcome {
  const SaveBusy();
}

/// Why a write produced nothing. Reported separately because the two need
/// different things from the pilot: a timeout is worth retrying where they
/// stand, a dropped link is not.
enum SaveFailure {
  /// The controller never answered. A timeout is the only failure detector
  /// the protocol has — the firmware answers neither a malformed frame nor a
  /// request its four-deep queue dropped.
  noAnswer,

  /// The link went away mid-request.
  linkLost,
}

/// Nothing came back, or the link went away.
class SaveFailed extends SaveOutcome {
  const SaveFailed([this.cause = SaveFailure.noAnswer]);

  final SaveFailure cause;
}

/// Owns the authenticate → write → re-read sequence for one connection.
///
/// Takes a [ControlSession] and nothing else, so every branch tests without a
/// radio. Authentication is per connection because the firmware makes it so:
/// `BleControl::onCentralDisconnected()` clears `authenticated_`, and this
/// object is built and discarded alongside the session.
///
/// The PIN is never stored. It arrives as an argument, is sent, and is not
/// kept — the flight panel never prompts for anything, because telemetry and
/// `CFG_GET` are unauthenticated.
class ConfigEditor {
  ConfigEditor(this._session, {this.onGroupRead});

  final ControlSession _session;

  /// Called with what the controller reported after a successful write.
  ///
  /// Without it the write lands and nothing above this class hears about it:
  /// the repository keeps the values it fetched when the connection opened,
  /// so reopening a settings screen shows the old numbers and the dials keep
  /// drawing the old thermal band for the rest of the connection. A band
  /// drawn from stale thresholds is the failure `CLAUDE.md` calls worse than
  /// no band at all, because it looks like information.
  final void Function(SaveOk)? onGroupRead;

  bool _authenticated = false;
  bool get authenticated => _authenticated;

  Future<SaveOutcome> savePower(PowerConfig config, {String? pin}) =>
      _save(ConfigGroup.power, config.encode(), pin);

  Future<SaveOutcome> saveThermal(ThermalConfig config, {String? pin}) =>
      _save(ConfigGroup.thermal, config.encode(), pin);

  Future<SaveOutcome> saveBms(BmsConfig config, {String? pin}) =>
      _save(ConfigGroup.bms, config.encode(), pin);

  Future<SaveOutcome> saveSystem(SystemConfig config, {String? pin}) =>
      _save(ConfigGroup.system, config.encode(), pin);

  /// Starts the controller's 5 s BLE scan for BMS devices.
  ///
  /// `ErrBusy` is a real answer, not a failure: the scanner is one resource
  /// and a scan is already running.
  Future<SaveOutcome> startBmsScan({String? pin}) =>
      _authenticatedAction(op: _opBmsScanStart, payload: const [], pin: pin);

  /// A plain `CFG_GET` of the System group, open like every read. The
  /// pairing wait needs it: `remoteMac` turning non-zero is the only signal
  /// that a remote was heard.
  Future<SystemConfig?> readSystemConfig() async {
    final result =
        await _session.request(op: _opCfgGet, payload: [ConfigGroup.system.id]);
    if (result is! ControlOk) return null;
    return SystemConfig.decode(result.payload);
  }

  /// Reads the scan's progress and results.
  ///
  /// **Open**: `opRequiresAuth` exempts it and `opAllowedWhileArmed` allows
  /// it, so it needs no PIN and answers while armed. Returns null when
  /// nothing came back — an empty scan and an unanswered poll are different
  /// things, and returning an empty state for the second would show the pilot
  /// "nenhum dispositivo" for a link that is simply not replying.
  Future<BmsScanState?> readBmsScan() async {
    final result = await _session.request(op: _opBmsScanStatus, payload: const []);
    if (result is! ControlOk) return null;
    return BmsScanState.decode(result.payload);
  }

  /// Puts the controller into pairing mode.
  ///
  /// It answers `Ok` the moment the flag is set, which is **not** the moment a
  /// remote is paired — `RemoteLink::onReceive` does that whenever the first
  /// remote packet arrives, with no timeout and no way to cancel. The only
  /// readback is `remoteMac` in the System group.
  Future<SaveOutcome> pairRemote({String? pin}) =>
      _authenticatedAction(op: _opRemotePair, payload: const [], pin: pin);

  /// Clears the paired MAC in NVS.
  ///
  /// Nothing tells the running `RemoteLink` to drop its peer, so a remote
  /// already talking may keep working until the controller restarts.
  Future<SaveOutcome> forgetRemote({String? pin}) =>
      _authenticatedAction(op: _opRemoteForget, payload: const [], pin: pin);

  /// Sets the volume and plays the preview tone.
  ///
  /// Not retried: the firmware plays a sound each time, so a resend after a
  /// timeout would beep twice. It is also the one control here whose failure
  /// the pilot hears rather than reads.
  Future<SaveOutcome> previewBuzzer(int volume, {String? pin}) {
    if (volume < 0 || volume > 100) {
      return Future.value(const SaveRejectedByController());
    }
    return _authenticatedAction(
      op: _opBuzzerPreview,
      payload: [volume],
      pin: pin,
      retry: false,
    );
  }

  /// The shared body of every authenticated action.
  ///
  /// Identical refusal mapping to `_save`, deliberately: armed reported
  /// before auth, `ErrBadOp` meaning this firmware cannot, `ErrAuth` meaning
  /// the session is gone. A parallel mapping would be free to drift from the
  /// one subsystem 3 got right.
  Future<SaveOutcome> _authenticatedAction({
    required int op,
    required List<int> payload,
    required String? pin,
    bool retry = true,
  }) async {
    if (!_authenticated) {
      if (pin == null) return const SaveNeedsPin();
      final auth = await _authenticate(pin);
      if (auth != null) return auth;
    }

    final result = retry
        ? await _retrying(op: op, payload: payload)
        : await _session.request(op: op, payload: payload);

    return switch (result) {
      ControlOk() => const SaveOk(),
      ControlRefused(:final status) => switch (status) {
          ControlStatus.errState => const SaveRefusedArmed(),
          ControlStatus.errAuth => _lostSession(),
          ControlStatus.errBadArg => const SaveRejectedByController(),
          ControlStatus.errBadOp => const SaveUnsupported(),
          ControlStatus.errBusy => const SaveBusy(),
          _ => const SaveFailed(),
        },
      ControlTimeout() => const SaveFailed(SaveFailure.noAnswer),
      ControlDropped() => const SaveFailed(SaveFailure.linkLost),
    };
  }

  Future<SaveOutcome> _save(
    ConfigGroup group,
    Uint8List encoded,
    String? pin,
  ) async {
    if (!_authenticated) {
      if (pin == null) return const SaveNeedsPin();

      final auth = await _authenticate(pin);
      if (auth != null) return auth;
    }

    final write = await _retrying(
      op: _opCfgSet,
      payload: [group.id, ...encoded],
    );

    switch (write) {
      case ControlOk():
        break;
      case ControlRefused(:final status):
        return switch (status) {
          // Reported before auth by the firmware's gate, so this is the
          // answer even when a PIN would also have been missing.
          ControlStatus.errState => const SaveRefusedArmed(),
          ControlStatus.errAuth => _lostSession(),
          ControlStatus.errBadArg => const SaveRejectedByController(),
          ControlStatus.errBadOp => const SaveUnsupported(),
          ControlStatus.errBusy => const SaveBusy(),
          _ => const SaveFailed(),
        };
      case ControlTimeout():
        return const SaveFailed(SaveFailure.noAnswer);
      case ControlDropped():
        return const SaveFailed(SaveFailure.linkLost);
    }

    return _reread(group);
  }

  /// Authenticates this connection. Returns null on success, or the outcome
  /// to report.
  ///
  /// Public because the DFU session needs the same session: the firmware's
  /// `authenticated_` is per connection, so a second flag here would have the
  /// pilot typing the PIN again to update firmware on a connection already
  /// authenticated to save settings.
  Future<SaveOutcome?> authenticate(String pin) => _authenticate(pin);

  /// Returns null when authentication succeeded, or the outcome to report.
  Future<SaveOutcome?> _authenticate(String pin) async {
    // The firmware compares raw characters against Settings' PIN and requires
    // an exact length match. No local length rule: inventing a 4-8 character
    // check that AUTH does not enforce would refuse something the controller
    // accepts.
    final result = await _retrying(op: _opAuth, payload: pin.codeUnits);

    switch (result) {
      case ControlOk():
        _authenticated = true;
        return null;
      case ControlRefused(:final status):
        return switch (status) {
          ControlStatus.errState => const SaveRefusedArmed(),
          ControlStatus.errAuth => _lostSession(SaveWrongPin.new),
          ControlStatus.errBusy => const SaveBusy(),
          _ => const SaveFailed(),
        };
      case ControlTimeout():
        return const SaveFailed(SaveFailure.noAnswer);
      case ControlDropped():
        return const SaveFailed(SaveFailure.linkLost);
    }
  }

  /// Asks the controller what it now holds, rather than assuming the values
  /// that were just sent.
  ///
  /// A band drawn from what the app *believes* it wrote is assumed data, and
  /// this codebase refuses assumed data everywhere else. A failure here does
  /// not undo the write — the controller already accepted it — so the outcome
  /// is still success, with the confirmation simply absent.
  Future<SaveOutcome> _reread(ConfigGroup group) async {
    final result = await _retrying(op: _opCfgGet, payload: [group.id]);
    if (result is! ControlOk) return const SaveOk();

    final outcome = switch (group) {
      ConfigGroup.power => SaveOk(power: PowerConfig.decode(result.payload)),
      ConfigGroup.thermal =>
        SaveOk(thermal: ThermalConfig.decode(result.payload)),
      ConfigGroup.bms => SaveOk(bms: BmsConfig.decode(result.payload)),
      ConfigGroup.system =>
        SaveOk(system: SystemConfig.decode(result.payload)),
    };

    onGroupRead?.call(outcome);
    return outcome;
  }

  SaveOutcome _lostSession(
      [SaveOutcome Function() make = _needsPinAfterLoss]) {
    // The firmware fails closed: a bad PIN clears whatever this connection had
    // already earned, so the app must not believe it is still authenticated.
    final hadSession = _authenticated;
    _authenticated = false;
    // Only report a *lost* session when there was one to lose.
    if (!hadSession && identical(make, _needsPinAfterLoss)) {
      return const SaveNeedsPin();
    }
    return make();
  }

  static SaveOutcome _needsPinAfterLoss() =>
      const SaveNeedsPin(sessionLost: true);

  /// Sends a request, resending only on a timeout.
  ///
  /// Safe for exactly the two opcodes used here: `AUTH` with the same correct
  /// PIN and `CFG_SET` with the same payload both land on the same state. It
  /// would not be safe for `PIN_CHANGE`, which is why the session itself
  /// never retries and each caller decides.
  Future<ControlResult> _retrying({
    required int op,
    required List<int> payload,
  }) async {
    ControlResult result = const ControlTimeout();
    for (var attempt = 0; attempt < _attempts; attempt++) {
      result = await _session.request(op: op, payload: payload);
      if (result is! ControlTimeout) return result;
    }
    return result;
  }
}
