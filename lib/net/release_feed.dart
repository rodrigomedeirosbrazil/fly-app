import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../state/app_update_policy.dart';
import '../state/github_release.dart';

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

/// The only code in the app that talks to the internet — the same role
/// `ble/` plays for the radio.
///
/// `dart:io`'s `HttpClient` rather than `package:http`: one GET does not
/// earn a dependency. Unauthenticated, GitHub allows 60 requests an hour per
/// IP; this makes one per app launch. `/releases/latest` already excludes
/// drafts and prereleases.
class GitHubReleaseFeed implements ReleaseFeed, FirmwareFeed {
  GitHubReleaseFeed({
    Uri? endpoint,
    this.timeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 15),
  }) : endpoint = endpoint ??
            Uri.https('api.github.com', '/repos/$kReleaseRepo/releases/latest');

  final Uri endpoint;

  /// Covers the whole exchange, not just the connect.
  final Duration timeout;

  /// How long a download may go without receiving a byte. Not a total
  /// limit: 1.6 MB on a weak signal at a launch site can legitimately take
  /// minutes, and what is wrong is a transfer that stopped moving.
  final Duration idleTimeout;

  /// The latest release of [repo] (`owner/name`).
  GitHubReleaseFeed.forRepo(
    String repo, {
    Duration timeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 15),
  }) : this(
          endpoint: Uri.https('api.github.com', '/repos/$repo/releases/latest'),
          timeout: timeout,
          idleTimeout: idleTimeout,
        );

  @override
  Future<String?> latestTag() async => (await latestRelease())?.tag;

  /// The latest release with its assets, or null for **any** failure — the
  /// same rule as [latestTag], which is now a view of this.
  @override
  Future<GitHubRelease?> latestRelease() async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await _fetch(client).timeout(timeout);
    } on IOException {
      return null; // no network, refused, TLS, reset
    } on TimeoutException {
      return null;
    } on FormatException {
      return null; // a body that is not UTF-8
    } finally {
      // Force: after a timeout the request is still open, and closing
      // gracefully would wait for it.
      client.close(force: true);
    }
  }

  /// [url] must be one the app built — see `firmwareDownloadUrl`. GitHub
  /// answers it with a 302 to its storage host, which `HttpClient` follows
  /// for a GET.
  @override
  Future<DownloadResult> download(
    Uri url, {
    required int expectedSize,
    void Function(int received)? onProgress,
    DownloadCancel? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) return const DownloadFailed();
    final client = HttpClient()..connectionTimeout = timeout;
    // Force-closing the client tears down the socket, which surfaces in the
    // loop below as an IOException — one exit path for both.
    unawaited(cancel?.whenCancelled.then((_) => client.close(force: true)));
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'aerovolt-app');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        // Bounded like the body: a refusal whose body stalls must not hang.
        await response.drain<void>().timeout(idleTimeout);
        return const DownloadFailed();
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(idleTimeout)) {
        bytes.add(chunk);
        // Past the announced size it cannot become right; stop paying for it.
        if (bytes.length > expectedSize) return const DownloadIncomplete();
        onProgress?.call(bytes.length);
      }
      if (bytes.length != expectedSize) return const DownloadIncomplete();
      return Downloaded(bytes.takeBytes());
    } on IOException {
      return const DownloadFailed(); // includes HttpException, RedirectException
    } on TimeoutException {
      return const DownloadFailed();
    } finally {
      client.close(force: true);
    }
  }

  Future<GitHubRelease?> _fetch(HttpClient client) async {
    final request = await client.getUrl(endpoint);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      // GitHub rejects API requests that carry no User-Agent.
      ..set(HttpHeaders.userAgentHeader, 'aerovolt-app');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    return parseRelease(await response.transform(utf8.decoder).join());
  }
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
