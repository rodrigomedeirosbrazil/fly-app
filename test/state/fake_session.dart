import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/state/control_session.dart';

/// Answers requests with whatever the test queued, in order.
class FakeSession implements ControlSession {
  final sent = <({int op, List<int> payload})>[];
  final _queued = <ControlResult>[];

  void queue(ControlResult r) => _queued.add(r);

  void queueOk([List<int> payload = const []]) => queue(ControlOk(payload));

  @override
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) async {
    sent.add((op: op, payload: payload));
    return _queued.isEmpty ? const ControlTimeout() : _queued.removeAt(0);
  }

  @override
  Stream<ControlResponse> get events => const Stream.empty();

  @override
  Duration get timeout => const Duration(seconds: 2);

  @override
  void dispose() {}
}
