import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/protocol/log_protocol.dart';
import 'package:fly_app/state/control_session.dart';
import 'package:fly_app/state/log_browser.dart';

import 'fake_session.dart';

List<int> page({
  int used = 1000,
  int total = 131072,
  int count = 0,
  bool more = false,
  List<(String, int)> entries = const [],
}) {
  final head = ByteData(12)
    ..setUint32(0, used, Endian.little)
    ..setUint32(4, total, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint8(10, more ? 1 : 0)
    ..setUint8(11, entries.length);
  final out = [...head.buffer.asUint8List()];
  for (final (name, size) in entries) {
    final s = ByteData(4)..setUint32(0, size, Endian.little);
    out
      ..addAll(s.buffer.asUint8List())
      ..add(name.length)
      ..addAll(name.codeUnits);
  }
  return out;
}

/// Answers each request from a list of completers the test resolves in
/// whatever order it likes.
class ManualSession implements ControlSession {
  final replies = <Completer<ControlResult>>[];

  @override
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) {
    final c = Completer<ControlResult>();
    replies.add(c);
    return c.future;
  }

  @override
  Stream<ControlResponse> get events => const Stream.empty();

  @override
  Duration get timeout => const Duration(seconds: 2);

  @override
  void dispose() {}
}

void main() {
  test('pages with the last name as cursor and lists newest first', () async {
    final s = FakeSession()
      ..queueOk(page(count: 3, more: true, entries: [
        ('20261001_001.csv', 100),
        ('20261001_002.csv', 200),
      ]))
      ..queueOk(page(count: 3, entries: [('20261002_001.csv', 300)]));
    final b = LogBrowser(s);

    await b.refresh();

    expect(s.sent.map((r) => r.op), [kOpLogList, kOpLogList]);
    expect(s.sent[0].payload, [0]);
    expect(s.sent[1].payload,
        [16, ...'20261001_002.csv'.codeUnits]);
    final loaded = b.state as LogListLoaded;
    expect(loaded.files.map((f) => f.name), [
      '20261002_001.csv',
      '20261001_002.csv',
      '20261001_001.csv',
    ]);
    expect(loaded.usedBytes, 1000);
    expect(loaded.totalBytes, 131072);
  });

  test('a timeout is retried, three times at most', () async {
    final s = FakeSession()
      ..queue(const ControlTimeout())
      ..queueOk(page());
    final b = LogBrowser(s);

    await b.refresh();

    expect(b.state, isA<LogListLoaded>());
    expect(s.sent, hasLength(2));
  });

  test('old firmware is unsupported, not failed', () async {
    final s = FakeSession()..queue(const ControlRefused(ControlStatus.errBadOp));
    final b = LogBrowser(s);
    await b.refresh();
    expect(b.state, isA<LogListUnsupported>());
  });

  test('armed is reported as armed', () async {
    final s = FakeSession()..queue(const ControlRefused(ControlStatus.errState));
    final b = LogBrowser(s);
    await b.refresh();
    expect(b.state, isA<LogListRefusedArmed>());
  });

  test('a page that does not decode fails the list', () async {
    final s = FakeSession()..queueOk([1, 2, 3]);
    final b = LogBrowser(s);
    await b.refresh();
    expect((b.state as LogListFailed).reason, LogListFailure.malformed);
  });

  test('a firmware that never stops paging is cut off', () async {
    final s = FakeSession();
    for (var i = 0; i < 70; i++) {
      s.queueOk(page(more: true, entries: [('${i.toString().padLeft(5, '0')}.csv', 1)]));
    }
    final b = LogBrowser(s, maxPages: 64);
    await b.refresh();
    expect((b.state as LogListFailed).reason, LogListFailure.malformed);
    expect(s.sent, hasLength(64));
  });

  test('an older refresh that answers late cannot overwrite a newer one',
      () async {
    final s = ManualSession();
    final b = LogBrowser(s);

    final first = b.refresh();
    final second = b.refresh();
    s.replies[1].complete(ControlOk(page(entries: [('20261002_001.csv', 2)])));
    await second;
    s.replies[0].complete(ControlOk(page(entries: [('20261001_001.csv', 1)])));
    await first;

    final loaded = b.state as LogListLoaded;
    expect(loaded.files.map((f) => f.name), ['20261002_001.csv']);
  });

  test('a cursor the encoder refuses fails the list instead of throwing',
      () async {
    // The last name of a page becomes the next cursor. A name the firmware
    // listed but the validator rejects would throw out of refresh() and leave
    // the screen on its spinner forever.
    final s = FakeSession()
      ..queueOk(page(more: true, entries: [('has space.csv', 1)]));
    final b = LogBrowser(s);

    await b.refresh();

    expect((b.state as LogListFailed).reason, LogListFailure.malformed);
    expect(s.sent, hasLength(1), reason: 'the second request never goes out');
  });
}
