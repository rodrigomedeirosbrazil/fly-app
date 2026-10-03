import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/log_protocol.dart';

/// Builds a wire-shaped LOG_LIST reply. Every setter is an offset assertion
/// against Part 1 of the spec.
List<int> listReply({
  int used = 0,
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

List<int> chunkReply(int offset, int fileSize, List<int> data) {
  final d = ByteData(8)
    ..setUint32(0, offset, Endian.little)
    ..setUint32(4, fileSize, Endian.little);
  return [...d.buffer.asUint8List(), ...data];
}

void main() {
  test('opcodes match the firmware', () {
    expect(kOpLogList, 0x40);
    expect(kOpLogRead, 0x41);
    expect(kOpLogDelete, 0x42);
    expect(kOpLogDeleteAll, 0x43);
  });

  group('isValidLogName', () {
    test('accepts what the Logger writes', () {
      expect(isValidLogName('20261002_003.csv'), isTrue);
      expect(isValidLogName('00012.csv'), isTrue);
      expect(isValidLogName('old.txt'), isTrue);
    });

    test('refuses paths, traversal, other extensions and long names', () {
      expect(isValidLogName('/20261002_003.csv'), isFalse);
      expect(isValidLogName('../x.csv'), isFalse);
      expect(isValidLogName('a.bin'), isFalse);
      expect(isValidLogName(''), isFalse);
      expect(isValidLogName('${'a' * 21}.csv'), isFalse); // 25 chars
      expect(isValidLogName('${'a' * 20}.csv'), isTrue); // 24 chars
    });
  });

  group('encoders', () {
    test('LOG_LIST is [cursorLen][cursor]', () {
      expect(encodeLogList(''), [0]);
      expect(encodeLogList('a.csv'), [5, ...'a.csv'.codeUnits]);
    });

    test('LOG_READ is [offset u32][maxLen][nameLen][name]', () {
      expect(
        encodeLogRead(name: 'a.csv', offset: 0x01020304, maxLen: 232),
        [0x04, 0x03, 0x02, 0x01, 232, 5, ...'a.csv'.codeUnits],
      );
    });

    test('the longest LOG_READ fits the 32-byte request slot', () {
      final name = '${'a' * 20}.csv';
      expect(encodeLogRead(name: name, offset: 0, maxLen: 1).length, 30);
    });

    test('LOG_DELETE is [nameLen][name]', () {
      expect(encodeLogDelete('a.csv'), [5, ...'a.csv'.codeUnits]);
    });

    test('an invalid name never reaches the wire', () {
      expect(() => encodeLogRead(name: '../a.csv', offset: 0, maxLen: 1),
          throwsArgumentError);
      expect(() => encodeLogDelete('a.bin'), throwsArgumentError);
    });
  });

  group('LogListPage.decode', () {
    test('reads the header and every entry', () {
      final page = LogListPage.decode(listReply(
        used: 49152,
        total: 131072,
        count: 2,
        more: true,
        entries: [('20261001_001.csv', 4100), ('20261002_001.csv', 7300)],
      ))!;

      expect(page.usedBytes, 49152);
      expect(page.totalBytes, 131072);
      expect(page.fileCount, 2);
      expect(page.hasMore, isTrue);
      expect(page.entries.map((e) => (e.name, e.size)),
          [('20261001_001.csv', 4100), ('20261002_001.csv', 7300)]);
    });

    test('an entry cut short rejects the whole page', () {
      final full = listReply(count: 1, entries: [('a.csv', 10)]);
      expect(LogListPage.decode(full.sublist(0, full.length - 1)), isNull);
    });

    test('a header cut short is rejected', () {
      expect(LogListPage.decode(listReply().sublist(0, 11)), isNull);
    });
  });

  group('LogChunk.decode', () {
    test('reads offset, size and data', () {
      final c = LogChunk.decode(chunkReply(232, 5000, [1, 2, 3]))!;
      expect(c.offset, 232);
      expect(c.fileSize, 5000);
      expect(c.data, [1, 2, 3]);
    });

    test('end of file is an empty chunk, not an error', () {
      expect(LogChunk.decode(chunkReply(5000, 5000, []))!.data, isEmpty);
    });

    test('shorter than the header is rejected', () {
      expect(LogChunk.decode([1, 2, 3]), isNull);
    });
  });

  test('the chunk limit follows the link and the 240-byte frame', () {
    // ATT payload = MTU - 3. RSP header 4 + offset/size 8 = 12 more.
    expect(logChunkLimit(244), 232); // MTU 247
    expect(logChunkLimit(182), 170); // MTU 185, iOS
    expect(logChunkLimit(514), 232); // MTU 517: capped by the frame
    expect(logChunkLimit(20), 8); // MTU 23
    expect(logChunkLimit(5), 1); // never zero
  });

  test('dated names read as a date and a flight number', () {
    expect(logDisplayName('20261002_003.csv'), '02/10/2026 · voo 3');
    expect(logDisplayName('00012.csv'), '00012.csv');
  });

  test('sizes read in bytes, then kilobytes', () {
    expect(formatLogSize(900), '900 B');
    expect(formatLogSize(4100), '4,0 KB');
    expect(formatLogSize(131072), '128,0 KB');
    expect(formatLogSize(1024 * 1024 - 1), '1024,0 KB');
    expect(formatLogSize(1024 * 1024), '1,0 MB');
    expect(formatLogSize(2000000), '1,9 MB');
  });
}
