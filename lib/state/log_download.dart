import 'dart:typed_data';

import '../protocol/control_frame.dart';
import '../protocol/log_protocol.dart';
import 'control_session.dart';

sealed class LogDownloadOutcome {
  const LogDownloadOutcome();
}

class LogDownloaded extends LogDownloadOutcome {
  const LogDownloaded(this.bytes);
  final Uint8List bytes;
}

/// Refused because the aircraft is armed — which is also when the Logger is
/// writing. Never a reason to prompt for a PIN: reads need none.
class LogDownloadRefusedArmed extends LogDownloadOutcome {
  const LogDownloadRefusedArmed();
}

/// Firmware without the log opcodes.
class LogDownloadUnsupported extends LogDownloadOutcome {
  const LogDownloadUnsupported();
}

/// The file was deleted between listing and reading.
class LogDownloadNotFound extends LogDownloadOutcome {
  const LogDownloadNotFound();
}

class LogDownloadCancelled extends LogDownloadOutcome {
  const LogDownloadCancelled();
}

enum LogDownloadFailure {
  /// Three attempts at the same offset went unanswered.
  noAnswer,

  /// The link went away.
  linkLost,

  /// The size changed between chunks. Cannot happen while disarmed, because
  /// the Logger only writes armed — so it means something this design did
  /// not expect, and stitching the halves together would hand the pilot a
  /// file that never existed.
  fileChanged,

  /// A reply this build cannot place: a wrong offset, a premature empty
  /// chunk, an overshoot, or bytes that do not decode.
  malformed,

  /// The controller is doing something else with the resource.
  busy,
}

class LogDownloadFailed extends LogDownloadOutcome {
  const LogDownloadFailed(this.reason);
  final LogDownloadFailure reason;
}

/// Reads one log file, offset by offset.
///
/// Pure: it takes a [ControlSession], so every branch tests without a radio,
/// the same way `DfuSession` does.
///
/// **Each read is idempotent**, so a timeout is retried at the same offset.
/// Integrity comes from the protocol rather than a checksum: replies are
/// acknowledged by the link layer, the echoed offset catches a misplaced
/// chunk, and the file cannot change while disarmed. Progress is bytes
/// *received*, never bytes requested.
class LogDownload {
  LogDownload(this._session, {required this.maxChunk, this.attempts = 3});

  final ControlSession _session;

  /// Data bytes per request — `logChunkLimit` of this connection's MTU.
  final int maxChunk;

  final int attempts;

  bool _cancelled = false;

  /// Stops before the next request. A request already in flight completes.
  void cancel() => _cancelled = true;

  Future<LogDownloadOutcome> fetch(
    String name, {
    void Function(int received, int total)? onProgress,
  }) async {
    // A name listed by the controller can still be one the encoder refuses;
    // letting that throw would leave the caller's busy flag set for good.
    if (!isValidLogName(name)) {
      return const LogDownloadFailed(LogDownloadFailure.malformed);
    }
    final out = BytesBuilder(copy: false);
    var offset = 0;
    int? size;

    while (true) {
      if (_cancelled) return const LogDownloadCancelled();

      final result = await _read(name, offset);
      switch (result) {
        case ControlOk(:final payload):
          final chunk = LogChunk.decode(payload);
          if (chunk == null || chunk.offset != offset) {
            return const LogDownloadFailed(LogDownloadFailure.malformed);
          }
          size ??= chunk.fileSize;
          if (chunk.fileSize != size) {
            return const LogDownloadFailed(LogDownloadFailure.fileChanged);
          }
          final next = offset + chunk.data.length;
          if ((chunk.data.isEmpty && offset < size) || next > size) {
            return const LogDownloadFailed(LogDownloadFailure.malformed);
          }
          out.add(chunk.data);
          offset = next;
          onProgress?.call(offset, size);
          // Done at the size, without spending a request on the empty
          // end-of-file chunk the firmware would answer next.
          if (offset == size) return LogDownloaded(out.takeBytes());
        case ControlRefused(:final status):
          return switch (status) {
            ControlStatus.errState => const LogDownloadRefusedArmed(),
            ControlStatus.errBadOp => const LogDownloadUnsupported(),
            ControlStatus.errNotFound => const LogDownloadNotFound(),
            ControlStatus.errBusy =>
              const LogDownloadFailed(LogDownloadFailure.busy),
            _ => const LogDownloadFailed(LogDownloadFailure.malformed),
          };
        case ControlTimeout():
          return const LogDownloadFailed(LogDownloadFailure.noAnswer);
        case ControlDropped():
          return const LogDownloadFailed(LogDownloadFailure.linkLost);
      }
    }
  }

  Future<ControlResult> _read(String name, int offset) async {
    final payload = encodeLogRead(name: name, offset: offset, maxLen: maxChunk);
    ControlResult result = const ControlTimeout();
    for (var i = 0; i < attempts; i++) {
      result = await _session.request(op: kOpLogRead, payload: payload);
      if (result is! ControlTimeout) return result;
    }
    return result;
  }
}
