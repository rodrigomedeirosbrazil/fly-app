import 'package:flutter/foundation.dart';

import '../net/release_feed.dart';
import '../protocol/control_info.dart';
import 'firmware_update_policy.dart';

enum FirmwareDownloadState { idle, downloading, downloaded, failed, incomplete }

/// The GitHub check and the optional download, for **one visit** to the
/// Firmware screen.
///
/// Created when the screen opens and disposed when it closes: the pilot asked
/// for the check by opening the screen, and leaving it cancels a download in
/// flight rather than spending their data on an image nobody will send. Not
/// part of `TelemetryRepository` (telemetry glue) nor of the app's
/// `UpdateChecker` (different repository, different lifetime).
///
/// Nothing is cached: without a network there is no download either, so a
/// remembered answer would offer a button that cannot work.
class FirmwareUpdateChecker extends ChangeNotifier {
  FirmwareUpdateChecker({
    required this._feed,
    required this.installedVersion,
    required this.controllerType,
  });

  final FirmwareFeed _feed;

  /// `INFO.appVersion`, or null on the `$XCTOD` path.
  final String? installedVersion;
  final ControllerType controllerType;

  bool _disposed = false;

  bool get checking => _checking;
  bool _checking = false;

  /// Null until the first check has answered.
  FirmwareAvailability? get availability => _availability;
  FirmwareAvailability? _availability;

  FirmwareDownloadState get downloadState => _downloadState;
  FirmwareDownloadState _downloadState = FirmwareDownloadState.idle;

  int get received => _received;
  int _received = 0;

  /// The announced size of the image being, or last, downloaded.
  int? get total => switch (_availability) {
    FirmwareAvailable(:final size) => size,
    _ => null,
  };

  /// The downloaded image, once [downloadState] is `downloaded`.
  Uint8List? get image => _image;
  Uint8List? _image;

  DownloadCancel? _cancel;

  /// Asks GitHub. Called when the screen opens, and again by "Tentar de novo".
  Future<void> check() async {
    if (_disposed || _checking) return;
    _checking = true;
    _notify();
    FirmwareAvailability result;
    try {
      final release = await _feed.latestRelease();
      result = evaluateFirmware(
        installedVersion: installedVersion,
        controllerType: controllerType,
        release: release,
      );
    } catch (_) {
      // The feed promises null for any failure; an Error that escapes anyway
      // must not leave the card on "Verificando…" forever.
      result = const FirmwareUnknown();
    }
    if (_disposed) return;
    _checking = false;
    _availability = result;
    _notify();
  }

  /// Downloads the available image. A no-op unless one is available and no
  /// download is running.
  Future<void> download() async {
    final available = _availability;
    if (_disposed || available is! FirmwareAvailable) return;
    if (_downloadState == FirmwareDownloadState.downloading) return;

    final cancel = _cancel = DownloadCancel();
    _downloadState = FirmwareDownloadState.downloading;
    _received = 0;
    _image = null;
    _notify();

    DownloadResult result;
    try {
      result = await _feed.download(
        firmwareDownloadUrl(available.tag, available.assetName),
        expectedSize: available.size,
        cancel: cancel,
        onProgress: (n) {
          if (_disposed) return;
          _received = n;
          _notify();
        },
      );
    } catch (_) {
      // The feed promises never to throw; an Error that escapes anyway must
      // not leave the card on "Baixando…" forever.
      result = const DownloadFailed();
    }
    if (_disposed) return;

    switch (result) {
      case Downloaded(:final bytes):
        _image = bytes;
        _downloadState = FirmwareDownloadState.downloaded;
      case DownloadIncomplete():
        _downloadState = FirmwareDownloadState.incomplete;
      case DownloadFailed():
        _downloadState = FirmwareDownloadState.failed;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}
