import 'package:flutter/services.dart';

import 'android_host.dart';

/// What the update notice needs from the host, on both platforms.
///
/// `package_info_plus` and `url_launcher` would be two dependencies to read
/// one integer and open one URL — the same trade `AndroidHost` already
/// refused for `device_info_plus`. Same channel as [AndroidHost]; iOS answers
/// it too, but only `buildNumber`.
///
/// Channel failures — a host that refuses the call or lacks the method — are
/// swallowed: no number means no notice, and a URL that cannot open leaves the
/// pilot where they were. Neither is worth an error on screen.
///
/// A reply of the wrong type is not a channel failure. It is a bug in the
/// native half, and is deliberately left to surface rather than be hidden.
class AppHost {
  const AppHost([this.channel = const MethodChannel(AndroidHost.channelName)]);

  final MethodChannel channel;

  /// `versionCode` on Android, `CFBundleVersion` on iOS — the `+N` of
  /// `pubspec.yaml` on both.
  Future<int?> buildNumber() async {
    try {
      return await channel.invokeMethod<int>('buildNumber');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens [url] in the browser. Android only — iOS does not implement it,
  /// because a release carries nothing an iPhone can install.
  Future<void> openUrl(Uri url) async {
    try {
      await channel.invokeMethod<void>('openUrl', {'url': url.toString()});
    } on PlatformException {
      // No browser installed. Nothing useful to say.
    } on MissingPluginException {
      // iOS, or a host from before this method.
    }
  }
}
