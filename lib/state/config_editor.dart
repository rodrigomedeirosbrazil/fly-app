import 'dart:typed_data';

import '../protocol/config_groups.dart';
import '../protocol/control_frame.dart';
import 'control_session.dart';

const int _opAuth = 0x01;
const int _opCfgGet = 0x10;
const int _opCfgSet = 0x11;

/// How many times an idempotent request is resent after a timeout.
const int _attempts = 3;

/// What happened to a save.
sealed class SaveOutcome {
  const SaveOutcome();
}

/// Written. [power] or [thermal] carries what the controller reported when
/// asked again, or null when that confirmation did not come back.
class SaveOk extends SaveOutcome {
  const SaveOk({this.power, this.thermal});
  final PowerConfig? power;
  final ThermalConfig? thermal;
}

/// No authenticated session. Prompt, then call again with a PIN.
class SaveNeedsPin extends SaveOutcome {
  const SaveNeedsPin();
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

/// Nothing came back, or the link went away.
class SaveFailed extends SaveOutcome {
  const SaveFailed();
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
  ConfigEditor(this._session);

  final ControlSession _session;

  bool _authenticated = false;
  bool get authenticated => _authenticated;

  Future<SaveOutcome> savePower(PowerConfig config, {String? pin}) =>
      _save(ConfigGroup.power, config.encode(), pin);

  Future<SaveOutcome> saveThermal(ThermalConfig config, {String? pin}) =>
      _save(ConfigGroup.thermal, config.encode(), pin);

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
          _ => const SaveFailed(),
        };
      case ControlTimeout():
      case ControlDropped():
        return const SaveFailed();
    }

    return _reread(group);
  }

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
          _ => const SaveFailed(),
        };
      case ControlTimeout():
      case ControlDropped():
        return const SaveFailed();
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

    return switch (group) {
      ConfigGroup.power => SaveOk(power: PowerConfig.decode(result.payload)),
      ConfigGroup.thermal =>
        SaveOk(thermal: ThermalConfig.decode(result.payload)),
      _ => const SaveOk(),
    };
  }

  SaveOutcome _lostSession([SaveOutcome Function() make = SaveNeedsPin.new]) {
    // The firmware fails closed: a bad PIN clears whatever this connection had
    // already earned, so the app must not believe it is still authenticated.
    _authenticated = false;
    return make();
  }

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
