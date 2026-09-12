import 'dart:async';
import 'dart:math' as math;

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

/// Something went wrong, and [reason] says what.
///
/// This used to be a bare `DfuFailed()` covering eight different causes --
/// including a missing PIN, which is the one that happens on every first
/// transfer. A pilot was shown "falha" with nothing to act on, and so was I.
class DfuFailed extends DfuOutcome {
  const DfuFailed([this.reason = DfuFailureReason.noAnswer]);

  final DfuFailureReason reason;
}

enum DfuFailureReason {
  /// The controller never answered. A timeout is the protocol's only failure
  /// detector.
  noAnswer,

  /// The link went away.
  linkLost,

  /// The controller rejected the request's arguments — a size or CRC it will
  /// not accept.
  rejected,

  /// Another long operation holds the flash.
  busy,

  /// The controller answered something this build could not read.
  malformed,
}

/// The controller refused to start in its current state.
///
/// **Not the same as armed**, though both arrive as `ErrState`. The firmware
/// returns it when `Update.begin()` fails, which in practice means a previous
/// transfer is still open. Reporting it as "a aeronave está armada" sent the
/// pilot looking for a switch that was already off.
class DfuNotReady extends DfuOutcome {
  const DfuNotReady();
}

/// No authenticated session. Prompt, then call [DfuSession.start] with a PIN.
class DfuNeedsPin extends DfuOutcome {
  const DfuNeedsPin();
}

/// The PIN was wrong. The firmware fails closed and has cleared the session.
class DfuWrongPin extends DfuOutcome {
  const DfuWrongPin();
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
  /// Authenticates the connection, returning true on success.
  ///
  /// `DFU_BEGIN`, `DFU_COMMIT` and `DFU_ABORT` are writes by the firmware's
  /// gate — `opRequiresAuth` exempts only `DFU_STATUS`. Without this the very
  /// first send of every connection came back `ErrAuth` and was reported as a
  /// bare failure.
  Future<bool> authenticate(String pin);

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
    this._windowBytes = 8192,
    this._packetGap = const Duration(milliseconds: 3),
  });

  /// How much is sent before asking the controller what arrived.
  ///
  /// Small enough that a drop wastes little and the progress bar moves;
  /// large enough that the poll's round trip is not the bottleneck. 8 KB is
  /// roughly 45 packets at a 185-byte iOS MTU.
  final int _windowBytes;

  /// A pause between packets. Writes without response have no flow control
  /// of their own, and the controller drops everything after the first packet
  /// it could not take.
  final Duration _packetGap;

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
  /// Starts a transfer. Pass [pin] when a previous attempt reported
  /// [DfuNeedsPin].
  ///
  /// `DFU_BEGIN` is a write by the firmware's gate, so a connection that has
  /// not authenticated is refused with `ErrAuth` before a single byte goes
  /// out. The PIN covers the whole connection, so one typed to save a setting
  /// already covers this.
  Future<void> start(Uint8List image, {String? pin}) async {
    final inspection = inspectImage(image);
    if (inspection.problem != null) {
      _outcome = DfuRejectedImage(inspection.problem!);
      _state = DfuTransferState.failed;
      notifyListeners();
      return;
    }

    if (pin != null && !await _transport.authenticate(pin)) {
      _outcome = const DfuWrongPin();
      _state = DfuTransferState.failed;
      notifyListeners();
      return;
    }

    // Clear anything a previous attempt left open, and ignore the answer.
    //
    // A failed transfer leaves the controller's Update session live, and
    // `Update.begin()` then refuses the next one with ErrState -- which
    // survives closing the app, because the state is on the controller. The
    // pilot has no way to reset it and no reason to know it exists. ABORT is
    // safe at any point, including when nothing is in progress, so starting
    // every attempt with one makes a retry mean what the pilot expects.
    await _transport.request(op: opDfuAbort);

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

  /// Reads `DFU_STATUS`, or reports why it could not and returns null.
  ///
  /// The one read the firmware leaves open: `opRequiresAuth` exempts it and
  /// `opAllowedWhileArmed` allows it, because the app polls it throughout a
  /// transfer.
  Future<DfuStatus?> _readStatus() async {
    final result = await _transport.request(op: opDfuStatus);
    if (result is! ControlOk) {
      _outcome = DfuLost(_controlResultToCause(result));
      _state = DfuTransferState.failed;
      notifyListeners();
      return null;
    }

    final status = DfuStatus.decode(result.payload);
    if (status == null) {
      _outcome = const DfuFailed(DfuFailureReason.malformed);
      _state = DfuTransferState.failed;
      notifyListeners();
      return null;
    }
    return status;
  }

  /// Streams the image in windows, checking after each one.
  ///
  /// **Not one sweep of the whole image.** The first version sent every packet
  /// before asking the controller anything, and on the aircraft that produced
  /// exactly what you would expect from it: minutes at 0% — because progress
  /// comes from the poll and there was none until the end — and then 19%,
  /// because a megabyte written as fast as the platform accepts overruns the
  /// controller's receive buffers. The firmware keeps only the highest
  /// **contiguous** offset, so everything after the first dropped packet is
  /// discarded. The next pass then re-sent 81% of the image at the same rate
  /// and lost most of it again.
  ///
  /// A window does three jobs at once: it bounds how much work a single drop
  /// can waste, it paces the writes — the round trip of the poll is time the
  /// controller spends draining — and it moves the progress bar with what
  /// actually arrived.
  Future<void> _streamData(Uint8List image, int chunkSize) async {
    final payloadSize = payloadPerPacket(chunkSize);

    while (_bytesAcknowledged < image.length) {
      if (_state != DfuTransferState.sending) return;

      final windowStart = _bytesAcknowledged;
      final windowEnd =
          math.min(image.length, windowStart + _windowBytes);

      var offset = windowStart;
      while (offset < windowEnd && _state == DfuTransferState.sending) {
        final take = math.min(payloadSize, windowEnd - offset);
        try {
          await _transport.writeData(encodeDfuData(
            offset: offset,
            bytes: image.sublist(offset, offset + take),
          ));
        } catch (_) {
          _outcome = const DfuLost(DfuFailure.linkLost);
          _state = DfuTransferState.failed;
          notifyListeners();
          return;
        }
        offset += take;

        // A gap between packets, when one is configured. Writes without
        // response are not flow-controlled by anything below this line.
        if (_packetGap > Duration.zero) await Future.delayed(_packetGap);
      }

      if (_state != DfuTransferState.sending) return;

      final status = await _readStatus();
      if (status == null) return;

      final advanced = status.received > _bytesAcknowledged;
      _bytesAcknowledged = status.received;
      _progress = status.received / image.length;
      notifyListeners();

      if (advanced) {
        _restarts = 0;
        continue;
      }

      // A window that moved nothing. Give the controller a moment — it may
      // still be draining — and try that window again.
      _restarts++;
      if (_restarts >= _maxRestarts) {
        _outcome = const DfuFailed(DfuFailureReason.noAnswer);
        _state = DfuTransferState.failed;
        notifyListeners();
        return;
      }
      await Future.delayed(_pollInterval);
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
          // NOT armed, though gateRequest() also uses ErrState for that: the
          // screen gates armed before anything reaches here, and the DFU
          // handlers return the same status for a refused Update.begin().
          // Claiming "armed" sent the pilot looking for a switch already off.
          ControlStatus.errState => const DfuNotReady(),
          ControlStatus.errBadOp => const DfuUnsupported(),
          ControlStatus.errAuth => const DfuNeedsPin(),
          ControlStatus.errBadArg =>
            const DfuFailed(DfuFailureReason.rejected),
          ControlStatus.errBusy => const DfuFailed(DfuFailureReason.busy),
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
