import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../state/app_update_policy.dart';
import '../state/github_release.dart';
import 'release_feed.dart';

/// The only code in the app that talks to the internet — the same role
/// `ble/` plays for the radio.
///
/// `dart:io`'s `HttpClient` rather than `package:http`: a GET and a download
/// do not earn a dependency. Unauthenticated, GitHub allows 60 requests an
/// hour per IP; the app makes one per launch and one per visit to the
/// Firmware screen, plus a download only when the pilot asks for it.
/// `/releases/latest` already excludes drafts and prereleases.
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
