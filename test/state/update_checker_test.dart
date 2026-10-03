import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/net/release_feed.dart';
import 'package:fly_app/state/app_update_policy.dart';
import 'package:fly_app/state/update_checker.dart';

class FakeFeed implements ReleaseFeed {
  FakeFeed([this.tag]);

  String? tag;
  Completer<String?>? gate;
  int calls = 0;

  @override
  Future<String?> latestTag() {
    calls++;
    return gate?.future ?? Future.value(tag);
  }
}

class MemoryStore implements TagStore {
  MemoryStore([this.value]);

  String? value;
  bool failing = false;

  @override
  Future<String?> read() async {
    if (failing) throw PlatformException(code: 'prefs');
    return value;
  }

  @override
  Future<void> write(String tag) async {
    if (failing) throw PlatformException(code: 'prefs');
    value = tag;
  }
}

void main() {
  late FakeFeed feed;
  late MemoryStore store;
  late List<Uri> opened;

  setUp(() {
    feed = FakeFeed();
    store = MemoryStore();
    opened = [];
  });

  UpdateChecker checker({int? installed = 2026100301, bool canOpen = true}) =>
      UpdateChecker(
        feed: feed,
        store: store,
        installedBuild: () async => installed,
        openUrl: (url) async => opened.add(url),
        canOpenRelease: canOpen,
      );

  test('before checking, nothing is known', () {
    final c = checker();
    expect(c.availability, isA<UpdateUnknown>());
    expect(c.installedLabel, isNull);
    expect(c.checking, isFalse);
  });

  test('a newer release on the network is available and remembered',
      () async {
    feed.tag = '2026-10-04.1';
    final c = checker();

    await c.check();

    expect(c.availability, const UpdateAvailable('2026-10-04.1'));
    expect(c.installedLabel, '2026-10-03.1');
    expect(c.checking, isFalse);
    expect(store.value, '2026-10-04.1');
  });

  test('the same release is up to date', () async {
    feed.tag = '2026-10-03.1';
    final c = checker();
    await c.check();
    expect(c.availability, isA<UpToDate>());
  });

  test('a build without a version number never asks the network', () async {
    feed.tag = '2026-10-04.1';
    final c = checker(installed: 1);

    await c.check();

    expect(feed.calls, 0);
    expect(c.installedLabel, isNull);
    expect(c.availability, isA<UpdateUnknown>());
    expect(c.checking, isFalse);
  });

  test('a host that reports no number never asks the network', () async {
    final c = checker(installed: null);
    await c.check();
    expect(feed.calls, 0);
    expect(c.availability, isA<UpdateUnknown>());
  });

  test('the cache answers before the network does', () async {
    // The pilot at a launch site with no signal.
    store.value = '2026-10-04.1';
    feed.gate = Completer<String?>();
    final c = checker();

    final done = c.check();
    await pumpEventQueue();

    expect(c.availability, const UpdateAvailable('2026-10-04.1'));
    expect(c.checking, isTrue);

    feed.gate!.complete('2026-10-05.1');
    await done;

    expect(c.availability, const UpdateAvailable('2026-10-05.1'));
    expect(store.value, '2026-10-05.1');
  });

  test('a failed refresh keeps the cached answer', () async {
    store.value = '2026-10-04.1';
    feed.tag = null; // the feed reports failure as null
    final c = checker();

    await c.check();

    expect(c.availability, const UpdateAvailable('2026-10-04.1'));
    expect(c.checking, isFalse);
  });

  test('the cache cannot invent a notice after updating', () async {
    // Cached 10-04 from before; the pilot has since installed 10-04.
    store.value = '2026-10-04.1';
    final c = checker(installed: 2026100401);
    await c.check();
    expect(c.availability, isA<UpToDate>());
  });

  test('no cache and no network is unknown, and done checking', () async {
    final c = checker();
    await c.check();
    expect(c.availability, isA<UpdateUnknown>());
    expect(c.checking, isFalse);
  });

  test('an unreadable tag from the network is neither shown nor stored',
      () async {
    feed.tag = 'latest';
    final c = checker();
    await c.check();
    expect(c.availability, isA<UpdateUnknown>());
    expect(store.value, isNull);
  });

  test('an unreadable cached tag is ignored', () async {
    store.value = 'garbage';
    final c = checker();
    await c.check();
    expect(c.availability, isA<UpdateUnknown>());
  });

  test('storage that fails does not stop the check', () async {
    store.failing = true;
    feed.tag = '2026-10-04.1';
    final c = checker();
    await c.check();
    expect(c.availability, const UpdateAvailable('2026-10-04.1'));
  });

  test('notifies listeners as the answer changes', () async {
    feed.tag = '2026-10-04.1';
    final c = checker();
    var notified = 0;
    c.addListener(() => notified++);

    await c.check();

    expect(notified, greaterThanOrEqualTo(2)); // started, finished
  });

  test('checks once, however many times it is asked', () async {
    final c = checker();
    await c.check();
    await c.check();
    expect(feed.calls, 1);
  });

  test('disposing mid-check does not throw when the answer lands', () async {
    feed.gate = Completer<String?>();
    final c = checker();
    final done = c.check();
    await pumpEventQueue();

    c.dispose();
    feed.gate!.complete('2026-10-04.1');

    await done; // would throw "used after being disposed" on notify
  });

  group('openRelease', () {
    test('opens the page the app built for the available tag', () async {
      feed.tag = '2026-10-04.1';
      final c = checker();
      await c.check();

      await c.openRelease();

      expect(opened, [releasePageUrl('2026-10-04.1')]);
    });

    test('opens nothing when up to date', () async {
      feed.tag = '2026-10-03.1';
      final c = checker();
      await c.check();
      await c.openRelease();
      expect(opened, isEmpty);
    });

    test('opens nothing where a release cannot be installed', () async {
      feed.tag = '2026-10-04.1';
      final c = checker(canOpen: false);
      await c.check();
      await c.openRelease();
      expect(opened, isEmpty);
    });
  });
}
