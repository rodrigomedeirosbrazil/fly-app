import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/mac_address.dart';
import 'config_editor.dart';

enum PairingState { idle, waiting, paired, gaveUp, refused }

/// Waits for a remote throttle to pair.
///
/// `REMOTE_PAIR` answers `Ok` the moment it sets a flag. The pairing itself
/// happens in `RemoteLink::onReceive` whenever the first remote packet
/// arrives — which may be never. There is no "is pairing" query, no cancel
/// opcode, and **no firmware timeout**.
///
/// So the only readback is `remoteMac` in the System group turning non-zero,
/// and the only limit is this app's own deadline. When it expires the
/// controller is **still listening**: the next remote powered on nearby will
/// be paired. [stillListening] exists to make the screen say that instead of
/// claiming a cancel the protocol cannot perform.
class RemotePairingController extends ChangeNotifier {
  RemotePairingController(
    this._editor, {
    this.pollInterval = const Duration(seconds: 1),
    this.deadline = const Duration(seconds: 60),
  });

  final ConfigEditor _editor;
  final Duration pollInterval;
  final Duration deadline;

  Timer? _timer;
  PairingState _state = PairingState.idle;
  List<int>? _pairedMac;
  SaveOutcome? _refusal;
  bool _stillListening = false;
  int _ticks = 0;

  PairingState get state => _state;
  List<int>? get pairedMac => _pairedMac;
  SaveOutcome? get refusal => _refusal;

  /// True once the controller has been told to pair and has not reported a
  /// remote. It stays true after [cancel] and after the deadline.
  bool get stillListening => _stillListening;

  Future<SaveOutcome> start({String? pin}) async {
    _refusal = null;
    _pairedMac = null;
    _ticks = 0;

    final outcome = await _editor.pairRemote(pin: pin);
    if (outcome is! SaveOk) {
      _refusal = outcome;
      _state = PairingState.refused;
      notifyListeners();
      return outcome;
    }

    _state = PairingState.waiting;
    _stillListening = true;
    _timer = Timer.periodic(pollInterval, (_) => _poll());
    notifyListeners();
    return outcome;
  }

  Future<void> _poll() async {
    _ticks++;

    final config = await _editor.readSystemConfig();

    // A missed tick is not a failure: the read is a plain CFG_GET and a
    // single unanswered one says nothing about the remote. Keep waiting --
    // but keep counting, because the deadline below is the only thing that
    // ends this wait. Returning here without reaching it left a pairing that
    // ran forever whenever the reads stopped answering, which is the one
    // condition under which the pilot most needs to be told.
    if (config != null && !isUnsetMac(config.remoteMac)) {
      _state = PairingState.paired;
      _pairedMac = config.remoteMac;
      _stillListening = false;
      _stopTimer();
      notifyListeners();
      return;
    }

    if (_ticks * pollInterval.inMilliseconds >= deadline.inMilliseconds) {
      // The controller is still listening. Nothing here tells it to stop,
      // because the protocol has no opcode that does.
      _state = PairingState.gaveUp;
      _stopTimer();
      notifyListeners();
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void cancel() {
    _stopTimer();
    _state = PairingState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
