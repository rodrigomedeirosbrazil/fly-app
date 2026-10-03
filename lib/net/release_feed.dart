import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../state/app_update_policy.dart';

/// The newest published release, as far as the network can tell.
///
/// An interface so `UpdateChecker` is tested without a socket.
abstract interface class ReleaseFeed {
  /// The latest release's tag, or null for **any** failure. There is nothing
  /// a caller could do differently for a timeout than for a 403, so they are
  /// not told apart.
  Future<String?> latestTag();
}

/// The only code in the app that talks to the internet — the same role
/// `ble/` plays for the radio.
///
/// `dart:io`'s `HttpClient` rather than `package:http`: one GET does not
/// earn a dependency. Unauthenticated, GitHub allows 60 requests an hour per
/// IP; this makes one per app launch. `/releases/latest` already excludes
/// drafts and prereleases.
class GitHubReleaseFeed implements ReleaseFeed {
  GitHubReleaseFeed({
    Uri? endpoint,
    this.timeout = const Duration(seconds: 10),
  }) : endpoint = endpoint ??
            Uri.https('api.github.com', '/repos/$kReleaseRepo/releases/latest');

  final Uri endpoint;

  /// Covers the whole exchange, not just the connect.
  final Duration timeout;

  @override
  Future<String?> latestTag() async {
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

  Future<String?> _fetch(HttpClient client) async {
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
    return parseLatestTag(await response.transform(utf8.decoder).join());
  }
}

/// `tag_name` from a `/releases/latest` body, or null when the body is not
/// a JSON object carrying a string there. Format validation is the policy's
/// job ([releaseBuildNumber]); this only reads.
String? parseLatestTag(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final tag = decoded['tag_name'];
    return tag is String ? tag : null;
  } on FormatException {
    return null;
  }
}
