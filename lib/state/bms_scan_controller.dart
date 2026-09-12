import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/bms_scan.dart';
import 'config_editor.dart';

/// Drives one BMS scan: start it, poll it, stop when it ends.
///
/// The controller's scan lasts 5 s and there is no notification when it
/// finishes — `BMS_SCAN_STATUS` is a plain getter — so polling is the only
/// way to know. Polling stops the moment the status leaves `scanning`, which
/// is what keeps this from being a background loop that outlives the screen.
class BmsScanController extends ChangeNotifier {
  BmsScanController(
    this._editor, {
    this.pollInterval = const Duration(seconds: 1),
    this.deadline = const Duration(seconds: 15),
  });

  final ConfigEditor _editor;
  final Duration pollInterval;

  /// How long to keep asking before calling the scan lost.
  ///
  /// Generous against the controller's 5 s scan, because the polls that fall
  /// inside it are the ones most likely to go unanswered.
  final Duration deadline;

  Timer? _timer;
  int _ticks = 0;
  BmsScanStatus _status = BmsScanStatus.idle;
  List<BmsScanResult> _results = const [];
  int _total = 0;
  SaveOutcome? _refusal;
  bool _lostContact = false;

  BmsScanStatus get status => _status;

  /// Sorted strongest first: the nearest device is the pilot's own, and a
  /// scan in a hangar can return a dozen.
  List<BmsScanResult> get results => _results;

  /// What the controller says it saw, which can exceed [results] when the
  /// reply was truncated to one frame.
  int get total => _total;

  bool get truncated => _total > _results.length;
  bool get isPolling => _timer != null;

  /// Set when the start was refused — armed, no PIN, busy, unsupported. The
  /// screen reports it with the same messages every other refusal uses.
  SaveOutcome? get refusal => _refusal;

  /// True when the scan ended because nothing ever answered, rather than
  /// because the controller reported a scan that failed. They need different
  /// things said: one is a link problem, the other is the controller unable
  /// to start scanning at all.
  bool get lostContact => _lostContact;

  Future<SaveOutcome> start({String? pin}) async {
    _refusal = null;
    _results = const [];
    _total = 0;
    _ticks = 0;
    _lostContact = false;
    _status = BmsScanStatus.scanning;
    notifyListeners();

    final outcome = await _editor.startBmsScan(pin: pin);
    if (outcome is! SaveOk) {
      _refusal = outcome;
      _status = BmsScanStatus.idle;
      _stopTimer();
      notifyListeners();
      return outcome;
    }

    _timer = Timer.periodic(pollInterval, (_) => _poll());
    notifyListeners();
    return outcome;
  }

  Future<void> _poll() async {
    _ticks++;
    final state = await _editor.readBmsScan();

    if (state == null) {
      // A missed poll is the normal case here, not a failure. The controller
      // is running a BLE scan with the same radio that carries this link --
      // it stops advertising for the whole 5 s -- so the replies most likely
      // to go missing are exactly the ones during the scan being watched.
      //
      // Ending the scan on the first silence is what made "Buscar BMS" look
      // like it did nothing: the status went to error, and the screen drew
      // nothing at all for that. Keep asking until the deadline; only then is
      // it really lost.
      if (_ticks * pollInterval.inMilliseconds >= deadline.inMilliseconds) {
        _status = BmsScanStatus.error;
        _lostContact = true;
        _stopTimer();
        notifyListeners();
      }
      return;
    }

    _status = state.status;
    _total = state.total;
    _results = [...state.results]..sort((a, b) => b.rssi.compareTo(a.rssi));

    if (state.status != BmsScanStatus.scanning) _stopTimer();
    notifyListeners();
  }

  void stop() {
    _stopTimer();
    notifyListeners();
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }
}
