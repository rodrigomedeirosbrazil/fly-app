import '../state/app_update_policy.dart';
import '../state/github_release.dart';
import 'release_feed.dart';

/// The web build's feed: never finds a release and never downloads.
///
/// A page served from GitHub Pages is always the newest app, so the update
/// notice has nothing to say, and the firmware image is picked from a file.
class GitHubReleaseFeed implements ReleaseFeed, FirmwareFeed {
  GitHubReleaseFeed({
    Uri? endpoint,
    this.timeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 15),
  }) : endpoint = endpoint ??
            Uri.https('api.github.com', '/repos/$kReleaseRepo/releases/latest');

  GitHubReleaseFeed.forRepo(
    String repo, {
    Duration timeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 15),
  }) : this(
          endpoint: Uri.https('api.github.com', '/repos/$repo/releases/latest'),
          timeout: timeout,
          idleTimeout: idleTimeout,
        );

  final Uri endpoint;
  final Duration timeout;
  final Duration idleTimeout;

  @override
  Future<String?> latestTag() async => null;

  @override
  Future<GitHubRelease?> latestRelease() async => null;

  @override
  Future<DownloadResult> download(
    Uri url, {
    required int expectedSize,
    void Function(int received)? onProgress,
    DownloadCancel? cancel,
  }) async =>
      const DownloadFailed();
}
