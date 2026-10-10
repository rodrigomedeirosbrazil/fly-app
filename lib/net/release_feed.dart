import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../state/github_release.dart';

// `HttpClient` is `dart:io`, which a web build cannot import. The web build
// gets a feed that never finds a release: the page is always the latest app,
// and the firmware image comes from the file picker.
export 'github_release_feed_io.dart'
    if (dart.library.js_interop) 'github_release_feed_web.dart';

/// The newest published release, as far as the network can tell.
///
/// An interface so `UpdateChecker` is tested without a socket.
abstract interface class ReleaseFeed {
  /// The latest release's tag, or null for **any** failure. There is nothing
  /// a caller could do differently for a timeout than for a 403, so they are
  /// not told apart.
  Future<String?> latestTag();
}

/// What the firmware check needs from the network. An interface so
/// `FirmwareUpdateChecker` is tested without a socket.
abstract interface class FirmwareFeed {
  /// The latest release with its assets, or null for any failure.
  Future<GitHubRelease?> latestRelease();

  /// Never throws.
  Future<DownloadResult> download(
    Uri url, {
    required int expectedSize,
    void Function(int received)? onProgress,
    DownloadCancel? cancel,
  });
}

/// `tag_name` from a `/releases/latest` body, or null. Kept for the app
/// update notice's tests; [parseRelease] is the parser.
String? parseLatestTag(String body) => parseRelease(body)?.tag;

/// A `/releases/latest` body, or null when it is not a JSON object carrying a
/// string `tag_name`. Format validation is the policies' job; this only reads.
///
/// An asset without a string `name` or a positive integer `size` is
/// **skipped**: one odd entry must not hide the image this controller needs,
/// and an asset whose size is unknown cannot be checked after download.
GitHubRelease? parseRelease(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final tag = decoded['tag_name'];
    if (tag is! String) return null;
    final assets = <ReleaseAsset>[];
    final raw = decoded['assets'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map<String, dynamic>) continue;
        final name = entry['name'];
        final size = entry['size'];
        if (name is String && size is int && size > 0) {
          assets.add(ReleaseAsset(name: name, size: size));
        }
      }
    }
    return GitHubRelease(tag: tag, assets: assets);
  } on FormatException {
    return null;
  }
}

sealed class DownloadResult {
  const DownloadResult();
}

final class Downloaded extends DownloadResult {
  const Downloaded(this.bytes);
  final Uint8List bytes;
}

/// The body ended short of, or ran past, the size the release announced.
/// Told apart from [DownloadFailed] because the pilot's next step differs:
/// this one is worth retrying on the same signal.
final class DownloadIncomplete extends DownloadResult {
  const DownloadIncomplete();
}

/// No network, refused, TLS, a non-200, an idle timeout, or cancelled.
final class DownloadFailed extends DownloadResult {
  const DownloadFailed();
}

/// Ends an in-flight [GitHubReleaseFeed.download]. The Firmware screen
/// cancels when it closes, so leaving it stops spending the pilot's data.
final class DownloadCancel {
  final Completer<void> _done = Completer<void>();

  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}
