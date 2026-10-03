import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/release_feed.dart';
import 'app_update_policy.dart';

/// Where the last release tag seen survives between launches.
abstract interface class TagStore {
  Future<String?> read();
  Future<void> write(String tag);
}

class PrefsTagStore implements TagStore {
  const PrefsTagStore();

  static const String key = 'latestReleaseTag';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String tag) async =>
      (await SharedPreferences.getInstance()).setString(key, tag);
}

/// Whether a newer build exists, for the connection screen and the settings
/// index. Not part of `TelemetryRepository`, which is telemetry glue and
/// nothing else.
///
/// Checks once per launch, never retries, and is independent of BLE: nothing
/// here can delay Conectar.
///
/// **The cache cannot invent a notice.** It holds the last tag seen, and the
/// comparison is always recomputed against the *installed* build — so after
/// updating, the notice disappears on its own, offline included. Its one
/// failure mode is a release deleted from GitHub.
class UpdateChecker extends ChangeNotifier {
  UpdateChecker({
    required this._feed,
    required this._store,
    required this._installedBuild,
    required this._openUrl,
    required this.canOpenRelease,
  });

  final ReleaseFeed _feed;
  final TagStore _store;
  final Future<int?> Function() _installedBuild;
  final Future<void> Function(Uri url) _openUrl;

  /// True where a release is something this phone can install — Android.
  /// On iOS the notice is text only.
  final bool canOpenRelease;

  int? _installed;
  String? _latestTag;
  bool _checking = false;
  bool _started = false;
  bool _disposed = false;

  /// The installed version in tag form, `2026-10-03.1`; null when the build
  /// carries no usable number.
  String? get installedLabel =>
      _installed == null ? null : formatBuildNumber(_installed!);

  UpdateAvailability get availability =>
      evaluateUpdate(installed: _installed, latestTag: _latestTag);

  /// True while the network has not answered yet.
  bool get checking => _checking;

  Future<void> check() async {
    if (_started) return;
    _started = true;
    _checking = true;
    _notify();

    _installed = await _quietly(_installedBuild);
    if (installedLabel == null) {
      // A build with no version number cannot be compared to anything, so
      // the network is not asked.
      _checking = false;
      _notify();
      return;
    }

    final cached = await _quietly(_store.read);
    if (cached != null && releaseBuildNumber(cached) != null) {
      _latestTag = cached;
      _notify();
    }

    final fresh = await _quietly(_feed.latestTag);
    if (fresh != null && releaseBuildNumber(fresh) != null) {
      _latestTag = fresh;
      await _quietly(() async {
        await _store.write(fresh);
        return null;
      });
    }
    // A failed refresh leaves a cached tag in place: it is still an answer.

    _checking = false;
    _notify();
  }

  /// Opens the page of the available release, on platforms that can install
  /// it. Does nothing otherwise.
  Future<void> openRelease() async {
    final current = availability;
    if (!canOpenRelease || current is! UpdateAvailable) return;
    await _openUrl(releasePageUrl(current.tag));
  }

  /// Storage and host failures become null: every one of them means "no
  /// answer", which the policy already handles as silence.
  Future<T?> _quietly<T>(Future<T?> Function() action) async {
    try {
      return await action();
    } on Exception {
      return null;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
