/// A GitHub release as this app reads it: the tag format both repositories
/// use, and the assets attached to it.
///
/// Pure: imports nothing from `package:flutter` or `dart:io`, so the update
/// policies that read it are table-tested in milliseconds. The network half
/// lives in `lib/net/release_feed.dart`.
library;

/// The tag format both fly-app's `release.yml` and fly-controller's
/// `build-and-release.yml` produce: `AAAA-MM-DD.N`.
final RegExp _tagPattern = RegExp(r'^(2\d{3})-(\d{2})-(\d{2})\.(0|[1-9]\d*)$');

/// `2026-10-03.1` → `2026100301`, the same flattening CI applies.
///
/// Null for any tag CI would refuse to build, including `N > 99`, where the
/// build number would stop increasing. **An unreadable tag never produces a
/// notice.**
int? releaseBuildNumber(String tag) {
  final match = _tagPattern.firstMatch(tag);
  if (match == null) return null;
  // tryParse: the tag comes from the network, and a digit run too long for an
  // int must be an unreadable tag, not a FormatException.
  final n = int.tryParse(match.group(4)!);
  if (n == null || n > 99) return null;
  final date = int.parse('${match.group(1)}${match.group(2)}${match.group(3)}');
  return date * 100 + n;
}

/// One file attached to a release. Only what the app uses: the name it is
/// matched by and the size the download is checked against.
final class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.size});

  final String name;
  final int size;

  @override
  bool operator ==(Object other) =>
      other is ReleaseAsset && other.name == name && other.size == size;

  @override
  int get hashCode => Object.hash(name, size);

  @override
  String toString() => 'ReleaseAsset($name, $size)';
}

final class GitHubRelease {
  GitHubRelease({required this.tag, required List<ReleaseAsset> assets})
      : assets = List.unmodifiable(assets);

  /// As GitHub reported it — **not** validated here. The policies decide.
  final String tag;
  final List<ReleaseAsset> assets;
}
