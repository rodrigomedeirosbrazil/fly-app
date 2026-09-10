import 'package:flutter/services.dart';

/// The two things the app needs from the Android host that no plugin gives it.
///
/// `device_info_plus` would be a fifth dependency, on every platform, to read
/// one integer; `permission_handler` can open the app's own settings page but
/// not the system location page.
///
/// Lives in `ble/` because that is the layer allowed to touch the platform.
/// The channel is injectable so the seam is testable without a device.
class AndroidHost {
  const AndroidHost([this.channel = const MethodChannel(channelName)]);

  static const String channelName = 'br.com.medeirostec.aerovolt/host';

  final MethodChannel channel;

  /// `Build.VERSION.SDK_INT`.
  Future<int> sdkInt() async {
    final level = await channel.invokeMethod<int>('sdkInt');
    if (level == null) {
      // Refused rather than defaulted. Every substitute is wrong in one
      // direction — too low asks a modern phone for location, too high skips
      // the permission an old phone needs — and both directions end in a
      // scan that finds nothing and says nothing.
      throw StateError('Android host returned no SDK_INT');
    }
    return level;
  }

  /// Opens the system location settings — the only route back from a location
  /// service switched off on API <= 30.
  Future<void> openLocationSettings() =>
      channel.invokeMethod<void>('openLocationSettings');
}
