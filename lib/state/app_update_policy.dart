/// Which build of the app is installed, against which one GitHub has.
///
/// Pure: imports nothing from `package:flutter`, so it is table-tested in
/// milliseconds, the same way `ble_permission_policy.dart` is.
///
/// The comparison key is the **build number**, not the version name. iOS
/// requires `CFBundleShortVersionString` to be period-separated integers, so
/// the tag `2026-10-03.1` cannot be a version name there — but its flattened
/// form `2026100301` is a valid `CFBundleVersion` and is already Android's
/// `versionCode`, monotonic by construction.
library;

import 'github_release.dart';

// Re-exported so existing importers keep finding it here.
export 'github_release.dart' show releaseBuildNumber;

/// The repository whose releases are the source of truth.
const String kReleaseRepo = 'rodrigomedeirosbrazil/fly-app';

/// `2026100301` → `2026-10-03.1`, so the installed version reads exactly like
/// the tag on the releases page.
///
/// Null for a number that is not ten digits starting with 2 — notably `1`, the
/// build number every build carried before the pubspec held the release.
String? formatBuildNumber(int build) {
  if (build < 2000000000 || build > 2999999999) return null;
  final n = build % 100;
  final date = (build ~/ 100).toString();
  return '${date.substring(0, 4)}-${date.substring(4, 6)}-'
      '${date.substring(6, 8)}.$n';
}

sealed class UpdateAvailability {
  const UpdateAvailability();
}

final class UpToDate extends UpdateAvailability {
  const UpToDate();
}

final class UpdateAvailable extends UpdateAvailability {
  const UpdateAvailable(this.tag);

  /// The release tag, already validated by [releaseBuildNumber].
  final String tag;

  @override
  bool operator ==(Object other) =>
      other is UpdateAvailable && other.tag == tag;

  @override
  int get hashCode => tag.hashCode;

  @override
  String toString() => 'UpdateAvailable($tag)';
}

/// No installed number, no release known, or a tag that does not parse. The
/// UI shows nothing for it on the connection screen.
final class UpdateUnknown extends UpdateAvailability {
  const UpdateUnknown();
}

/// Only a release **strictly** newer than the installed build is a notice. An
/// installed build ahead of the latest release — a developer build before the
/// tag exists — is up to date, not a downgrade offer.
UpdateAvailability evaluateUpdate({
  required int? installed,
  required String? latestTag,
}) {
  if (installed == null || formatBuildNumber(installed) == null) {
    return const UpdateUnknown();
  }
  if (latestTag == null) return const UpdateUnknown();
  final latest = releaseBuildNumber(latestTag);
  if (latest == null) return const UpdateUnknown();
  return latest > installed ? UpdateAvailable(latestTag) : const UpToDate();
}

/// The release page for [tag].
///
/// **The app opens only URLs it built**, from a tag that passed
/// [releaseBuildNumber]. The API response's `html_url` is never used, so
/// nothing the network says can choose where the browser goes.
Uri releasePageUrl(String tag) {
  if (releaseBuildNumber(tag) == null) {
    throw ArgumentError.value(tag, 'tag', 'not a release tag');
  }
  return Uri.https('github.com', '/$kReleaseRepo/releases/tag/$tag');
}
