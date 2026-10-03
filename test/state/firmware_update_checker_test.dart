import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/net/release_feed.dart';
import 'package:fly_app/protocol/control_info.dart';
import 'package:fly_app/state/github_release.dart';
import 'package:fly_app/state/firmware_update_checker.dart';
import 'package:fly_app/state/firmware_update_policy.dart';

import 'fake_firmware_feed.dart';

void main() {
  late FakeFirmwareFeed feed;
  late FirmwareUpdateChecker checker;

  setUp(() {
    feed = FakeFirmwareFeed();
    checker = FirmwareUpdateChecker(
      feed: feed,
      installedVersion: '2026-09-12.1',
      controllerType: ControllerType.xag,
    );
  });

  tearDown(() => checker.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('checking, then the policy\'s answer', () async {
    expect(checker.checking, isFalse);
    final done = checker.check();
    expect(checker.checking, isTrue);
    expect(checker.availability, isNull);

    feed.releaseCalls.single.complete(firmwareRelease());
    await done;

    expect(checker.checking, isFalse);
    expect(checker.availability, isA<FirmwareAvailable>());
  });

  test('a failed check is unknown, and check() again asks again', () async {
    final first = checker.check();
    feed.releaseCalls.single.complete(null);
    await first;
    expect(checker.availability, const FirmwareUnknown());

    final second = checker.check();
    expect(feed.releaseCalls, hasLength(2));
    feed.releaseCalls.last.complete(firmwareRelease());
    await second;
    expect(checker.availability, isA<FirmwareAvailable>());
  });

  test(
    'a feed that throws anyway is unknown, not a check left running',
    () async {
      final throwing = _ThrowingFeed();
      final c = FirmwareUpdateChecker(
        feed: throwing,
        installedVersion: 'dev',
        controllerType: ControllerType.xag,
      );
      addTearDown(c.dispose);

      await c.check();

      expect(c.checking, isFalse);
      expect(c.availability, const FirmwareUnknown());
    },
  );

  Future<void> available() async {
    final done = checker.check();
    feed.releaseCalls.single.complete(firmwareRelease());
    await done;
  }

  test('download asks for the app-built URL and the announced size', () async {
    await available();

    final done = checker.download();
    expect(checker.downloadState, FirmwareDownloadState.downloading);

    final call = feed.downloadCalls.single;
    expect(
      call.url,
      firmwareDownloadUrl('2026-10-02.2', 'firmware-xag-2026-10-02.2.bin'),
    );
    expect(call.expectedSize, 4);

    call.onProgress!(2);
    expect(checker.received, 2);
    expect(checker.total, 4);

    call.result.complete(Downloaded(firmwareBytes()));
    await done;

    expect(checker.downloadState, FirmwareDownloadState.downloaded);
    expect(checker.image, firmwareBytes());
  });

  test(
    'a failed and an incomplete download are told apart, and retry',
    () async {
      await available();

      var done = checker.download();
      feed.downloadCalls.last.result.complete(const DownloadFailed());
      await done;
      expect(checker.downloadState, FirmwareDownloadState.failed);
      expect(checker.image, isNull);

      done = checker.download();
      feed.downloadCalls.last.result.complete(const DownloadIncomplete());
      await done;
      expect(checker.downloadState, FirmwareDownloadState.incomplete);

      done = checker.download();
      feed.downloadCalls.last.result.complete(Downloaded(firmwareBytes()));
      await done;
      expect(checker.downloadState, FirmwareDownloadState.downloaded);
      expect(feed.downloadCalls, hasLength(3));
    },
  );

  test('download does nothing unless an image is available', () async {
    final done = checker.check();
    feed.releaseCalls.single.complete(null);
    await done;

    await checker.download();

    expect(feed.downloadCalls, isEmpty);
    expect(checker.downloadState, FirmwareDownloadState.idle);
  });

  test('a second download while one runs is ignored', () async {
    await available();

    final first = checker.download();
    await checker.download();

    expect(feed.downloadCalls, hasLength(1));
    feed.downloadCalls.single.result.complete(Downloaded(firmwareBytes()));
    await first;
  });

  test('dispose cancels the download and nothing notifies after it', () async {
    await available();
    var notified = 0;
    checker.addListener(() => notified++);

    final done = checker.download();
    final call = feed.downloadCalls.single;
    final before = notified;
    checker.dispose();

    expect(call.cancel!.isCancelled, isTrue);
    call.onProgress!(2);
    call.result.complete(const DownloadFailed());
    await done;
    await settle();

    expect(notified, before);

    // tearDown disposes again; make that a no-op for this test.
    checker = FirmwareUpdateChecker(
      feed: feed,
      installedVersion: null,
      controllerType: ControllerType.xag,
    );
  });

  test('a check that answers after dispose changes nothing', () async {
    final done = checker.check();
    var notified = 0;
    checker.addListener(() => notified++);
    final call = feed.releaseCalls.single;
    checker.dispose();

    call.complete(firmwareRelease());
    await done;
    await settle();

    expect(notified, 0);
    expect(checker.checking, isTrue); // frozen where dispose found it

    checker = FirmwareUpdateChecker(
      feed: feed,
      installedVersion: null,
      controllerType: ControllerType.xag,
    );
  });

  test(
    'a download that throws anyway is failed, not left downloading',
    () async {
      final c = FirmwareUpdateChecker(
        feed: _ThrowingDownloadFeed(),
        installedVersion: '2026-09-12.1',
        controllerType: ControllerType.xag,
      );
      addTearDown(c.dispose);
      await c.check();

      await c.download();

      expect(c.downloadState, FirmwareDownloadState.failed);
    },
  );
}

class _ThrowingFeed implements FirmwareFeed {
  @override
  Future<Never> latestRelease() async => throw StateError('escaped');

  @override
  Future<DownloadResult> download(
    Uri url, {
    required int expectedSize,
    void Function(int)? onProgress,
    DownloadCancel? cancel,
  }) async => const DownloadFailed();
}

class _ThrowingDownloadFeed implements FirmwareFeed {
  @override
  Future<GitHubRelease?> latestRelease() async => firmwareRelease();

  @override
  Future<DownloadResult> download(
    Uri url, {
    required int expectedSize,
    void Function(int)? onProgress,
    DownloadCancel? cancel,
  }) async => throw StateError('escaped');
}
