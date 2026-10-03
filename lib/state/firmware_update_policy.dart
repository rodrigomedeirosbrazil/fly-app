/// Which firmware the controller runs, against which one GitHub has, and
/// which file is this controller's.
///
/// Pure: imports nothing from `package:flutter` or `dart:io`, table-tested
/// like `app_update_policy.dart`.
///
/// **The eighth hand-copied fly-controller contract in this repo.** The asset
/// names come from fly-controller's `.github/workflows/build-and-release.yml`
/// (`firmware-tmotor-<tag>.bin`, `firmware-xag-<tag>.bin`). A rename there
/// makes [evaluateFirmware] answer [FirmwareNoAssetForType] — the download
/// stops being offered; it never fetches the wrong file.
library;

import '../protocol/control_info.dart';
import 'github_release.dart';

const String kFirmwareRepo = 'rodrigomedeirosbrazil/fly-controller';

sealed class FirmwareAvailability {
  const FirmwareAvailability();
}

final class FirmwareUpToDate extends FirmwareAvailability {
  const FirmwareUpToDate();
}

final class FirmwareAvailable extends FirmwareAvailability {
  const FirmwareAvailable({
    required this.tag,
    required this.assetName,
    required this.size,
    required this.installedUnreadable,
  });

  /// Already validated by [releaseBuildNumber].
  final String tag;

  /// Built by [firmwareAssetName] and found, exactly, in the release.
  final String assetName;

  /// As the release announced it; the download is checked against it.
  final int size;

  /// The installed version is not a release tag (`dev`, empty, an old
  /// scheme), so the app cannot say it is up to date and offers the latest.
  final bool installedUnreadable;

  @override
  bool operator ==(Object other) =>
      other is FirmwareAvailable &&
      other.tag == tag &&
      other.assetName == assetName &&
      other.size == size &&
      other.installedUnreadable == installedUnreadable;

  @override
  int get hashCode => Object.hash(tag, assetName, size, installedUnreadable);

  @override
  String toString() =>
      'FirmwareAvailable($tag, $assetName, $size, unreadable: $installedUnreadable)';
}

/// The controller's type is unknown, or the release has no file for it.
final class FirmwareNoAssetForType extends FirmwareAvailability {
  const FirmwareNoAssetForType();
}

/// No release known (no network, rate limit, no release) or a tag that does
/// not parse.
final class FirmwareUnknown extends FirmwareAvailability {
  const FirmwareUnknown();
}

/// The file name fly-controller's CI gives this type's image, or null for a
/// type it builds nothing for.
String? firmwareAssetName(ControllerType type, String tag) => switch (type) {
      ControllerType.xag => 'firmware-xag-$tag.bin',
      ControllerType.tmotor => 'firmware-tmotor-$tag.bin',
      ControllerType.unknown => null,
    };

/// [installedVersion] is `INFO.appVersion` as reported; [controllerType] is
/// `INFO.controllerType`, a compile-time constant of the firmware build and
/// so trustworthy even on a `dev` build.
FirmwareAvailability evaluateFirmware({
  required String? installedVersion,
  required ControllerType controllerType,
  required GitHubRelease? release,
}) {
  if (release == null) return const FirmwareUnknown();
  final latest = releaseBuildNumber(release.tag);
  if (latest == null) return const FirmwareUnknown();

  final installed =
      installedVersion == null ? null : releaseBuildNumber(installedVersion);
  if (installed != null && installed >= latest) return const FirmwareUpToDate();

  final name = firmwareAssetName(controllerType, release.tag);
  if (name == null) return const FirmwareNoAssetForType();
  // Exact match only. A prefix or suffix match would accept a `.sig`, or an
  // asset left over from another tag.
  final asset = release.assets.where((a) => a.name == name).firstOrNull;
  if (asset == null) return const FirmwareNoAssetForType();

  return FirmwareAvailable(
    tag: release.tag,
    assetName: name,
    size: asset.size,
    installedUnreadable: installed == null,
  );
}

/// Where [assetName] of [tag] downloads from.
///
/// **The app downloads only from URLs it built**, from a tag that passed
/// [releaseBuildNumber] and a name [firmwareAssetName] produces for it. The
/// API's `browser_download_url` is never read, so nothing the network says
/// chooses where the bytes come from — the same rule as `releasePageUrl`.
Uri firmwareDownloadUrl(String tag, String assetName) {
  if (releaseBuildNumber(tag) == null) {
    throw ArgumentError.value(tag, 'tag', 'not a release tag');
  }
  final built = {
    firmwareAssetName(ControllerType.xag, tag),
    firmwareAssetName(ControllerType.tmotor, tag),
  };
  if (!built.contains(assetName)) {
    throw ArgumentError.value(
        assetName, 'assetName', 'not a firmware asset of $tag');
  }
  return Uri.https(
      'github.com', '/$kFirmwareRepo/releases/download/$tag/$assetName');
}
