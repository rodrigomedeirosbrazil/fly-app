import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/protocol/log_protocol.dart';
import 'package:fly_app/state/control_session.dart';
import 'package:fly_app/state/log_download.dart';

import 'fake_session.dart';

List<int> chunk(int offset, int size, List<int> data) {
  final d = ByteData(8)
    ..setUint32(0, offset, Endian.little)
    ..setUint32(4, size, Endian.little);
  return [...d.buffer.asUint8List(), ...data];
}

int offsetOf(List<int> readPayload) =>
    ByteData.sublistView(Uint8List.fromList(readPayload))
        .getUint32(0, Endian.little);

void main() {
  test('reads the file in chunks and stops at its size', () async {
    final s = FakeSession()
      ..queueOk(chunk(0, 5, [1, 2, 3]))
      ..queueOk(chunk(3, 5, [4, 5]));
    final progress = <(int, int)>[];

    final outcome = await LogDownload(s, maxChunk: 3)
        .fetch('a.csv', onProgress: (r, t) => progress.add((r, t)));

    expect((outcome as LogDownloaded).bytes, [1, 2, 3, 4, 5]);
    expect(s.sent.map((r) => r.op), [kOpLogRead, kOpLogRead]);
    expect(s.sent.map((r) => offsetOf(r.payload)), [0, 3]);
    expect(s.sent.first.payload[4], 3, reason: 'maxLen is the chunk size');
    expect(progress, [(3, 5), (5, 5)]);
  });

  test('an empty file is one request', () async {
    final s = FakeSession()..queueOk(chunk(0, 0, []));
    final outcome = await LogDownload(s, maxChunk: 100).fetch('a.csv');
    expect((outcome as LogDownloaded).bytes, isEmpty);
    expect(s.sent, hasLength(1));
  });

  test('a timeout asks for the same offset again', () async {
    final s = FakeSession()
      ..queueOk(chunk(0, 4, [1, 2]))
      ..queue(const ControlTimeout())
      ..queueOk(chunk(2, 4, [3, 4]));

    final outcome = await LogDownload(s, maxChunk: 2).fetch('a.csv');

    expect((outcome as LogDownloaded).bytes, [1, 2, 3, 4]);
    expect(s.sent.map((r) => offsetOf(r.payload)), [0, 2, 2]);
  });

  test('three silent attempts in a row give up', () async {
    final s = FakeSession(); // every request times out
    final outcome = await LogDownload(s, maxChunk: 2).fetch('a.csv');
    expect((outcome as LogDownloadFailed).reason, LogDownloadFailure.noAnswer);
    expect(s.sent, hasLength(3));
  });

  test('a chunk for another offset is not stitched in', () async {
    final s = FakeSession()..queueOk(chunk(10, 20, [1, 2]));
    final outcome = await LogDownload(s, maxChunk: 2).fetch('a.csv');
    expect((outcome as LogDownloadFailed).reason, LogDownloadFailure.malformed);
  });

  test('a file that changes size mid-download is reported as such', () async {
    final s = FakeSession()
      ..queueOk(chunk(0, 4, [1, 2]))
      ..queueOk(chunk(2, 6, [3, 4]));
    final outcome = await LogDownload(s, maxChunk: 2).fetch('a.csv');
    expect(
        (outcome as LogDownloadFailed).reason, LogDownloadFailure.fileChanged);
  });

  test('an empty chunk before the end is not end of file', () async {
    final s = FakeSession()..queueOk(chunk(0, 4, []));
    final outcome = await LogDownload(s, maxChunk: 2).fetch('a.csv');
    expect((outcome as LogDownloadFailed).reason, LogDownloadFailure.malformed);
  });

  test('refusals map to what they mean', () async {
    Future<LogDownloadOutcome> refused(ControlStatus st) {
      final s = FakeSession()..queue(ControlRefused(st));
      return LogDownload(s, maxChunk: 2).fetch('a.csv');
    }

    expect(await refused(ControlStatus.errState), isA<LogDownloadRefusedArmed>());
    expect(await refused(ControlStatus.errBadOp), isA<LogDownloadUnsupported>());
    expect(await refused(ControlStatus.errNotFound), isA<LogDownloadNotFound>());
    expect(
      ((await refused(ControlStatus.errBusy)) as LogDownloadFailed).reason,
      LogDownloadFailure.busy,
    );
  });

  test('a dropped link is not retried', () async {
    final s = FakeSession()..queue(const ControlDropped());
    final outcome = await LogDownload(s, maxChunk: 2).fetch('a.csv');
    expect((outcome as LogDownloadFailed).reason, LogDownloadFailure.linkLost);
    expect(s.sent, hasLength(1));
  });

  test('cancel stops before the next request', () async {
    final s = FakeSession()
      ..queueOk(chunk(0, 4, [1, 2]))
      ..queueOk(chunk(2, 4, [3, 4]));
    final d = LogDownload(s, maxChunk: 2);

    final outcome = await d.fetch('a.csv', onProgress: (_, _) => d.cancel());

    expect(outcome, isA<LogDownloadCancelled>());
    expect(s.sent, hasLength(1));
  });
}
