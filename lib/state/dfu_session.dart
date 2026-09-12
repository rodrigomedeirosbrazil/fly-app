import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/control_frame.dart';
import '../protocol/dfu_protocol.dart';
import 'control_session.dart';

/// Outcome of a DFU transfer.
sealed class DfuOutcome {
  const DfuOutcome();
}

/// Transfer completed and controller is ready to commit.
class DfuReady extends DfuOutcome {
  const DfuReady();
}

/// Transfer aborted by the user.
class DfuAborted extends DfuOutcome {
  const DfuAborted();
}

/// Transfer committed and controller is applying it.
class DfuCommitted extends DfuOutcome {
  const DfuCommitted();
}

/// The image has a problem: empty, not ESP32, or too large.
class DfuRejectedImage extends DfuOutcome {
  const DfuRejectedImage(this.problem);
  final ImageProblem problem;
}

/// Aircraft is armed. Never prompt for a PIN in response to this.
class DfuRefusedArmed extends DfuOutcome {
  const DfuRefusedArmed();
}

/// This firmware has no DFU support.
class DfuUnsupported extends DfuOutcome {
  const DfuUnsupported();
}

/// The transfer timed out or the link went away.
class DfuFailed extends DfuOutcome {
  const DfuFailed();
}

/// Why a transfer stopped.
enum DfuFailure {
  /// The controller never answered.
  noAnswer,

  /// The link went away mid-transfer.
  linkLost,
}

/// Transfer lost connection before reaching ready.
class DfuLost extends DfuOutcome {
  const DfuLost(this.cause);
  final DfuFailure cause;
}

/// Session state machine for the screen.
enum DfuTransferState { idle, sending, verifying, ready, committed, aborted, failed }

/// The transport layer — requests over CMD/RSP, bulk data without response.
abstract class DfuTransport {
  /// A `CMD` request, answered on `RSP`. Same shape ConfigEditor uses.
  Future<ControlResult> request({required int op, List<int> payload});

  /// A write **without response** on the data characteristic.
  Future<void> writeData(List<int> bytes);
}

/// Drives a firmware update over BLE, restarting from acknowledged bytes.
///
/// Pure decision logic: takes an abstract transport, so transfers are tested
/// in milliseconds with no radio.
class DfuSession extends ChangeNotifier {
  DfuSession(
    this._transport, {
    this._pollInterval = const Duration(seconds: 1),
    this._maxRestarts = 3,
  });

  final DfuTransport _transport;
  final Duration _pollInterval;
  final int _maxRestarts;

  DfuTransferState _state = DfuTransferState.idle;
  double _progress = 0;
  int _bytesAcknowledged = 0;
  DfuOutcome? _outcome;
  Timer? _timer;
  int _restarts = 0;

  DfuTransferState get state => _state;
  double get progress => _progress;
  int get bytesAcknowledged => _bytesAcknowledged;
  DfuOutcome? get outcome => _outcome;

  bool get isTransferring => _state == DfuTransferState.sending ||
      _state == DfuTransferState.verifying;

  /// Start a transfer with the given image.
  Future<void> start(Uint8List image) async {
    final inspection = inspectImage(image);
    if (inspection.problem != null) {
      _outcome = DfuRejectedImage(inspection.problem!);
      _state = DfuTransferState.failed;
      notifyListeners();
      return;
    }

    _state = DfuTransferState.sending;
    _progress = 0;
    _bytesAcknowledged = 0;
    _restarts = 0;
    _outcome = null;
    notifyListeners();

    // Send DFU_BEGIN with size and CRC. Not retried.
    final beginResult = await _transport.request(
      op: opDfuBegin,
      payload: encodeDfuBegin(sizeBytes: image.length, crc: inspection.crc32),
    );

    final beginOutcome = _mapRefusal(beginResult);
    if (beginOutcome != null) {
      _state = DfuTransferState.failed;
      _outcome = beginOutcome;
      notifyListeners();
      return;
    }

    // Start streaming data.
    final statusResult = await _transport.request(op: opDfuStatus);
    if (statusResult is! ControlOk) {
      _outcome = DfuLost(_controlResultToCause(statusResult));
      _state = DfuTransferState.failed;
      notifyListeners();
      return;
    }

    final status = DfuStatus.decode(statusResult.payload);
    if (status == null) {
      _outcome = DfuFailed();
      _state = DfuTransferState.failed;
      notifyListeners();
      return;
    }

    await _streamData(image, status.chunkSize);
  }

  /// Stream the image data and wait for verification.
  Future<void> _streamData(Uint8List image, int chunkSize) async {
    final payloadSize = payloadPerPacket(chunkSize);

    // Outer loop: send all data, possibly restarting from acknowledged bytes
    while (_bytesAcknowledged < image.length) {
      if (_state != DfuTransferState.sending) return;

      // Inner loop: send packets from where we left off
      int offset = _bytesAcknowledged;
      while (offset < image.length && _state == DfuTransferState.sending) {
        final bytesToSend =
            (offset + payloadSize <= image.length)
                ? payloadSize
                : (image.length - offset);
        final chunk = image.sublist(offset, offset + bytesToSend);

        try {
          await _transport.writeData(
            encodeDfuData(offset: offset, bytes: chunk),
          );
        } catch (_) {
          _outcome = DfuLost(DfuFailure.linkLost);
          _state = DfuTransferState.failed;
          notifyListeners();
          return;
        }

        offset += bytesToSend;
      }

      if (_state != DfuTransferState.sending) return;

      // Poll status to see what the controller received.
      final statusResult = await _transport.request(op: opDfuStatus);
      if (statusResult is! ControlOk) {
        _outcome = DfuLost(_controlResultToCause(statusResult));
        _state = DfuTransferState.failed;
        notifyListeners();
        return;
      }

      final status = DfuStatus.decode(statusResult.payload);
      if (status == null) {
        _outcome = DfuFailed();
        _state = DfuTransferState.failed;
        notifyListeners();
        return;
      }

      _bytesAcknowledged = status.received;
      _progress = status.received / image.length;
      notifyListeners();

      // If we've sent everything but controller hasn't received it all,
      // we might be stuck or packets are arriving slowly.
      if (offset >= image.length && _bytesAcknowledged < image.length) {
        // Wait a bit before polling again to detect if stuck.
        await Future.delayed(_pollInterval);

        final statusResult2 = await _transport.request(op: opDfuStatus);
        if (statusResult2 is! ControlOk) {
          _outcome = DfuLost(_controlResultToCause(statusResult2));
          _state = DfuTransferState.failed;
          notifyListeners();
          return;
        }

        final status2 = DfuStatus.decode(statusResult2.payload);
        if (status2 == null) {
          _outcome = DfuFailed();
          _state = DfuTransferState.failed;
          notifyListeners();
          return;
        }

        // Check if progress changed.
        if (status2.received == _bytesAcknowledged) {
          // No progress: we're stuck.
          _restarts++;
          if (_restarts >= _maxRestarts) {
            _outcome = DfuFailed();
            _state = DfuTransferState.failed;
            notifyListeners();
            return;
          }
          // Loop continues: restart from _bytesAcknowledged
        } else {
          // Progress made: reset restart counter
          _restarts = 0;
          _bytesAcknowledged = status2.received;
          _progress = status2.received / image.length;
          notifyListeners();
          // Loop continues: send more from _bytesAcknowledged
        }
      }
    }

    // All data sent and acknowledged. Wait for verification.
    _state = DfuTransferState.verifying;
    notifyListeners();

    while (_state == DfuTransferState.verifying) {
      await Future.delayed(_pollInterval);

      final statusResult = await _transport.request(op: opDfuStatus);
      if (statusResult is! ControlOk) {
        _outcome = DfuLost(_controlResultToCause(statusResult));
        _state = DfuTransferState.failed;
        notifyListeners();
        return;
      }

      final status = DfuStatus.decode(statusResult.payload);
      if (status == null) {
        _outcome = DfuFailed();
        _state = DfuTransferState.failed;
        notifyListeners();
        return;
      }

      if (status.state == DfuState.ready) {
        _state = DfuTransferState.ready;
        _outcome = const DfuReady();
        _progress = 1.0;
        notifyListeners();
        return;
      }

      if (status.state == DfuState.error) {
        _outcome = DfuFailed();
        _state = DfuTransferState.failed;
        notifyListeners();
        return;
      }
    }
  }

  /// Commit the update and reboot.
  Future<void> commit() async {
    if (_state != DfuTransferState.ready) {
      return;
    }

    _state = DfuTransferState.committed;
    await _transport.request(op: opDfuCommit);
    _outcome = const DfuCommitted();
    notifyListeners();
  }

  /// Abort the transfer.
  Future<void> abort() async {
    _state = DfuTransferState.aborted;
    _outcome = const DfuAborted();
    await _transport.request(op: opDfuAbort);
    _timer?.cancel();
    notifyListeners();
  }

  /// Map a control result to a DFU outcome if it's a refusal.
  DfuOutcome? _mapRefusal(ControlResult result) {
    return switch (result) {
      ControlOk() => null,
      ControlRefused(:final status) => switch (status) {
          ControlStatus.errState => const DfuRefusedArmed(),
          ControlStatus.errBadOp => const DfuUnsupported(),
          ControlStatus.errAuth => const DfuFailed(),
          ControlStatus.errBadArg => const DfuFailed(),
          ControlStatus.errBusy => const DfuFailed(),
          ControlStatus.unknown => const DfuFailed(),
          ControlStatus.ok => const DfuFailed(), // Should not happen
        },
      ControlTimeout() => const DfuFailed(),
      ControlDropped() => const DfuLost(DfuFailure.linkLost),
    };
  }

  /// Convert a control result to a failure cause.
  DfuFailure _controlResultToCause(ControlResult result) {
    return switch (result) {
      ControlTimeout() => DfuFailure.noAnswer,
      ControlDropped() => DfuFailure.linkLost,
      ControlOk() => DfuFailure.noAnswer,
      ControlRefused() => DfuFailure.noAnswer,
    };
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
