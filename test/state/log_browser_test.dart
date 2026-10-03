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
}
