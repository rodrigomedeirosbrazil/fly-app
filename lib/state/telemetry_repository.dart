import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/fly_controller_link.dart';
import '../protocol/line_assembler.dart';
import '../protocol/xctod_frame.dart';
import 'link_health.dart';

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
  late final StreamSubscription<List<int>> _payloadSub;
  late final Timer _ticker;

  LinkStatus _status = LinkStatus.idle;
  LinkStatus get status => _status;

  /// The frame to render, or null when there is nothing trustworthy to show.
  XctodFrame? get frame => _health.frameAt(_now());

  /// True when a frame was received and has since aged out. Distinguishes
  /// "signal lost" from "never connected".
  bool get isStale => _health.isStale(_now());

  int get rejectedFrames => _health.rejectedCount;

  Future<void> start() async {
    if (!await _link.ensurePermissions()) return;
    await _link.connect();
  }

  Future<void> stop() => _link.disconnect();

  void _onStatus(LinkStatus s) {
    _status = s;
    if (s == LinkStatus.disconnected || s == LinkStatus.idle) {
      _assembler.reset();
      _health.reset();
    }
    notifyListeners();
  }

  void _onPayload(List<int> bytes) {
    final now = _now();
    for (final line in _assembler.add(bytes)) {
      _health.onLine(line, now);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.cancel();
    _statusSub.cancel();
    _payloadSub.cancel();
    _link.dispose();
    super.dispose();
  }
}
