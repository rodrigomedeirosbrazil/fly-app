import 'dart:async';
import 'dart:typed_data';

import 'package:fly_app/net/release_feed.dart';
import 'package:fly_app/state/github_release.dart';

/// Each call parks on a completer the test resolves, so every intermediate
/// state can be observed.
class FakeFirmwareFeed implements FirmwareFeed {
  final releaseCalls = <Completer<GitHubRelease?>>[];
  final downloadCalls =
      <
        ({
          Uri url,
          int expectedSize,
          void Function(int)? onProgress,
          DownloadCancel? cancel,
          Completer<DownloadResult> result,
        })
      >[];

  @override
  Future<GitHubRelease?> latestRelease() {
    final c = Completer<GitHubRelease?>();
    releaseCalls.add(c);
    return c.future;
  }

  @override
  Future<DownloadResult> download(
    Uri url, {
    required int expectedSize,
    void Function(int received)? onProgress,
    DownloadCancel? cancel,
  }) {
    final c = Completer<DownloadResult>();
    downloadCalls.add((
      url: url,
      expectedSize: expectedSize,
      onProgress: onProgress,
      cancel: cancel,
      result: c,
    ));
    return c.future;
  }
}

GitHubRelease firmwareRelease([String tag = '2026-10-02.2']) => GitHubRelease(
  tag: tag,
  assets: [
    ReleaseAsset(name: 'firmware-tmotor-$tag.bin', size: 4),
    ReleaseAsset(name: 'firmware-xag-$tag.bin', size: 4),
  ],
);

/// A 4-byte "image" matching [firmwareRelease]'s sizes, with the ESP32 magic.
Uint8List firmwareBytes() => Uint8List.fromList([0xE9, 1, 2, 3]);
