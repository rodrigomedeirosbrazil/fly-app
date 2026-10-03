import 'package:flutter/foundation.dart';

import '../protocol/control_frame.dart';
import '../protocol/log_protocol.dart';
import 'control_session.dart';

sealed class LogListState {
  const LogListState();
}

class LogListLoading extends LogListState {
  const LogListLoading();
}

class LogListLoaded extends LogListState {
  const LogListLoaded({
    required this.files,
    required this.usedBytes,
    required this.totalBytes,
  });

  /// Newest first. Dated names sort chronologically; legacy undated ones
  /// sort below them.
  final List<LogFileEntry> files;
  final int usedBytes;
  final int totalBytes;
}

/// Firmware without the log opcodes.
class LogListUnsupported extends LogListState {
  const LogListUnsupported();
}

class LogListRefusedArmed extends LogListState {
  const LogListRefusedArmed();
}

enum LogListFailure { noAnswer, linkLost, malformed, busy }

class LogListFailed extends LogListState {
  const LogListFailed(this.reason);
  final LogListFailure reason;
}

/// The list of log files on the controller, for one screen.
///
/// Pages `LOG_LIST` by cursor — the last name received — so a file deleted
/// between two pages can neither be skipped nor repeated. `LOG_LIST` is a
/// read, so a timeout is retried.
class LogBrowser extends ChangeNotifier {
  LogBrowser(this._session, {this.attempts = 3, this.maxPages = 64});

  final ControlSession _session;
  final int attempts;

  /// A guard against a firmware whose "more" flag never clears. 64 pages of
  /// at least seven files is far beyond any partition this firmware has.
  final int maxPages;

  LogListState _state = const LogListLoading();
  LogListState get state => _state;

  bool _disposed = false;

  void _set(LogListState s) {
    if (_disposed) return;
    _state = s;
    notifyListeners();
  }

  Future<void> refresh() async {
    _set(const LogListLoading());

    final files = <LogFileEntry>[];
    var cursor = '';
    var used = 0;
    var total = 0;

    for (var pageNo = 0; pageNo < maxPages; pageNo++) {
      final result = await _list(cursor);
      if (_disposed) return;

      switch (result) {
        case ControlOk(:final payload):
          final page = LogListPage.decode(payload);
          if (page == null) {
            return _set(const LogListFailed(LogListFailure.malformed));
          }
          files.addAll(page.entries);
          used = page.usedBytes;
          total = page.totalBytes;
          if (!page.hasMore || page.entries.isEmpty) {
            files.sort((a, b) => b.name.compareTo(a.name));
            return _set(LogListLoaded(
              files: List.unmodifiable(files),
              usedBytes: used,
              totalBytes: total,
            ));
          }
          cursor = page.entries.last.name;
        case ControlRefused(:final status):
          return _set(switch (status) {
            ControlStatus.errBadOp => const LogListUnsupported(),
            ControlStatus.errState => const LogListRefusedArmed(),
            ControlStatus.errBusy => const LogListFailed(LogListFailure.busy),
            _ => const LogListFailed(LogListFailure.malformed),
          });
        case ControlTimeout():
          return _set(const LogListFailed(LogListFailure.noAnswer));
        case ControlDropped():
          return _set(const LogListFailed(LogListFailure.linkLost));
      }
    }

    _set(const LogListFailed(LogListFailure.malformed));
  }

  Future<ControlResult> _list(String cursor) async {
    ControlResult result = const ControlTimeout();
    for (var i = 0; i < attempts; i++) {
      result = await _session.request(
        op: kOpLogList,
        payload: encodeLogList(cursor),
      );
      if (result is! ControlTimeout) return result;
    }
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
