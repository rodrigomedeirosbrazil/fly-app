import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/state/github_release.dart';

void main() {
  test('releaseBuildNumber reads the shared AAAA-MM-DD.N format', () {
    // Both repositories tag this way; the full table lives in
    // app_update_policy_test.dart, which still imports it from there.
    expect(releaseBuildNumber('2026-10-02.2'), 2026100202);
    expect(releaseBuildNumber('dev'), isNull);
  });

  test('a release carries its tag and its assets, unmodifiable', () {
    final release = GitHubRelease(
      tag: '2026-10-02.2',
      assets: const [ReleaseAsset(name: 'a.bin', size: 10)],
    );

    expect(release.tag, '2026-10-02.2');
    expect(release.assets.single, const ReleaseAsset(name: 'a.bin', size: 10));
    expect(() => release.assets.add(const ReleaseAsset(name: 'b', size: 1)),
        throwsUnsupportedError);
  });
}
