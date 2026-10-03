/// The flight-log opcodes (`0x40–0x43`).
///
/// **The seventh hand-copied fly-controller contract in this repo.** The
/// definition of record is `src/BleControl/ControlProtocol.h`; the design is
/// Part 1 of `docs/superpowers/specs/2026-10-02-portal-replacement-design.md`.
/// Fields are read by offset, with the same hazard as every other copy: a
/// field that moves there decodes silently into the wrong one here.
///
/// The CSV inside a file is opaque to this app. It is exported as bytes and
/// never parsed.
library;

import 'dart:math' as math;
import 'dart:typed_data';

const int kOpLogList = 0x40;
const int kOpLogRead = 0x41;
const int kOpLogDelete = 0x42;
const int kOpLogDeleteAll = 0x43;

/// Longest name the firmware accepts. 24 keeps `LOG_READ` at 30 bytes, under
/// the 32-byte request slot that drops oversized requests without a reply.
const int kMaxLogNameLength = 24;

/// Most data bytes one `LOG_READ` reply can carry: 240-byte payload minus the
/// 8-byte offset/size header.
const int kMaxLogChunk = 232;

/// `RSP` header (4) plus the `LOG_READ` reply header (8).
const int _readOverhead = 12;

/// A file name the firmware will accept: no path, no traversal, `.csv` or
/// `.txt`, printable ASCII, at most [kMaxLogNameLength] characters.
bool isValidLogName(String name) {
  if (name.isEmpty || name.length > kMaxLogNameLength) return false;
  if (name.contains('/') || name.contains('..')) return false;
  if (!name.codeUnits.every((c) => c > 0x20 && c < 0x7F)) return false;
  return name.endsWith('.csv') || name.endsWith('.txt');
}

void _checkName(String name) {
  if (!isValidLogName(name)) {
    throw ArgumentError.value(name, 'name', 'not a log file name');
  }
}

/// `[cursorLen u8][cursor…]`. An empty cursor starts from the first file.
List<int> encodeLogList(String cursor) {
  if (cursor.isNotEmpty) _checkName(cursor);
  return [cursor.length, ...cursor.codeUnits];
}

/// `[offset u32][maxLen u8][nameLen u8][name…]`.
List<int> encodeLogRead({
  required String name,
  required int offset,
  required int maxLen,
}) {
  _checkName(name);
  RangeError.checkValueInInterval(offset, 0, 0xFFFFFFFF, 'offset');
  RangeError.checkValueInInterval(maxLen, 1, 255, 'maxLen');
  final o = ByteData(4)..setUint32(0, offset, Endian.little);
  return [...o.buffer.asUint8List(), maxLen, name.length, ...name.codeUnits];
}

/// `[nameLen u8][name…]`.
List<int> encodeLogDelete(String name) {
  _checkName(name);
  return [name.length, ...name.codeUnits];
}

/// Data bytes to ask for per read, given the ATT payload this phone can take
/// (MTU − 3).
///
/// Per download, never cached: the same phone and controller have negotiated
/// 247 on one connection and 517 on the next.
int logChunkLimit(int attPayload) =>
    math.max(1, math.min(kMaxLogChunk, attPayload - _readOverhead));

class LogFileEntry {
  const LogFileEntry({required this.name, required this.size});
  final String name;
  final int size;
}

/// One `LOG_LIST` reply.
class LogListPage {
  const LogListPage({
    required this.usedBytes,
    required this.totalBytes,
    required this.fileCount,
    required this.hasMore,
    required this.entries,
  });

  /// The filesystem's own figures, true whatever the retention policy.
  final int usedBytes;
  final int totalBytes;

  /// Every listable file, not just this page.
  final int fileCount;

  /// More entries exist after the last one here; ask again with its name.
  final bool hasMore;

  final List<LogFileEntry> entries;

  static const int _headerLength = 12;

  /// Null when the reply cannot be trusted. An entry cut short rejects the
  /// page whole — a list with its last file missing would look complete.
  static LogListPage? decode(List<int> bytes) {
    if (bytes.length < _headerLength) return null;
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final d = ByteData.sublistView(data);

    final n = d.getUint8(11);
    final entries = <LogFileEntry>[];
    var off = _headerLength;
    for (var i = 0; i < n; i++) {
      if (off + 5 > data.length) return null;
      final size = d.getUint32(off, Endian.little);
      final nameLen = data[off + 4];
      off += 5;
      if (off + nameLen > data.length) return null;
      entries.add(LogFileEntry(
        name: String.fromCharCodes(data.sublist(off, off + nameLen)),
        size: size,
      ));
      off += nameLen;
    }

    return LogListPage(
      usedBytes: d.getUint32(0, Endian.little),
      totalBytes: d.getUint32(4, Endian.little),
      fileCount: d.getUint16(8, Endian.little),
      hasMore: d.getUint8(10) & 0x01 != 0,
      entries: List.unmodifiable(entries),
    );
  }
}

/// One `LOG_READ` reply.
class LogChunk {
  const LogChunk({
    required this.offset,
    required this.fileSize,
    required this.data,
  });

  /// Echoed from the request, so a misplaced chunk is detectable.
  final int offset;

  /// The file's size at the moment of this read.
  final int fileSize;

  /// Empty at end of file.
  final List<int> data;

  static LogChunk? decode(List<int> bytes) {
    if (bytes.length < 8) return null;
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final d = ByteData.sublistView(data);
    return LogChunk(
      offset: d.getUint32(0, Endian.little),
      fileSize: d.getUint32(4, Endian.little),
      data: Uint8List.sublistView(data, 8),
    );
  }
}

final RegExp _dated = RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{3})\.(csv|txt)$');

/// `20261002_003.csv` → `02/10/2026 · voo 3`. The date is the controller's
/// UTC date exactly as named; the name carries no time of day to convert.
/// Any other name is shown as it is.
String logDisplayName(String name) {
  final m = _dated.firstMatch(name);
  if (m == null) return name;
  return '${m[3]}/${m[2]}/${m[1]} · voo ${int.parse(m[4]!)}';
}

/// Bytes, then kilobytes with a Brazilian decimal comma.
String formatLogSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  return '${(bytes / 1024).toStringAsFixed(1).replaceAll('.', ',')} KB';
}
