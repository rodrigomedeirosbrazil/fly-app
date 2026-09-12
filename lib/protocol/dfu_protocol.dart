/// The DFU half of the Fly Control protocol.
///
/// Control travels over `CMD`/`RSP` and **bulk travels over its own
/// characteristic**, because `CONTROL_QUEUED_PAYLOAD_MAX` is 32 bytes and the
/// firmware's request queue is four deep — a 1.8 MB image through it would be
/// 57,000 round trips into a queue that drops the newest on overflow.
///
/// The data characteristic is written **without response**, which is what
/// makes the transfer take a minute rather than ten. Nothing about it is
/// reliable, so every packet carries its absolute offset and the whole image
/// carries a CRC32.
library;

import 'dart:typed_data';

const int opDfuBegin = 0x50;
const int opDfuCommit = 0x51;
const int opDfuAbort = 0x52;
const int opDfuStatus = 0x53;

/// One OTA slot, from the firmware's `min_spiffs.csv`: `app0` and `app1` are
/// `0x1E0000` bytes each.
const int kMaxImageBytes = 0x1E0000;

/// Every ESP32 application image starts with this.
const int kEsp32ImageMagic = 0xE9;

enum DfuState { idle, receiving, verifying, ready, error, unknown }

enum ImageProblem { empty, notEsp32, tooLarge }

class ImageInspection {
  const ImageInspection({
    required this.sizeBytes,
    required this.crc32,
    required this.problem,
  });

  final int sizeBytes;
  final int crc32;

  /// Null when the file can be sent. **A null problem does not mean the image
  /// is for this controller** — XAG and Tmotor run different builds and
  /// nothing in the file says which. The screen says so.
  final ImageProblem? problem;
}

ImageInspection inspectImage(Uint8List bytes) {
  ImageProblem? problem;
  if (bytes.isEmpty) {
    problem = ImageProblem.empty;
  } else if (bytes[0] != kEsp32ImageMagic) {
    problem = ImageProblem.notEsp32;
  } else if (bytes.length > kMaxImageBytes) {
    problem = ImageProblem.tooLarge;
  }

  return ImageInspection(
    sizeBytes: bytes.length,
    crc32: problem == null ? crc32(bytes) : 0,
    problem: problem,
  );
}

/// CRC-32/ISO-HDLC, the one `esp_rom_crc32_le` and every zip tool agree on.
/// The firmware computes this over the same bytes; a disagreement refuses
/// every update, so the standard vectors are pinned in the test.
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b & 0xFF;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int> encodeDfuBegin({required int sizeBytes, required int crc}) {
  final d = ByteData(8);
  d.setUint32(0, sizeBytes, Endian.little);
  d.setUint32(4, crc, Endian.little);
  return d.buffer.asUint8List();
}

/// `[offset u32][bytes…]` on the data characteristic.
///
/// The offset is absolute and in every packet, because a write without
/// response can be dropped without either side being told.
List<int> encodeDfuData({required int offset, required List<int> bytes}) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out).setUint32(0, offset, Endian.little);
  out.setRange(4, out.length, bytes);
  return out;
}

/// How many image bytes fit in one packet of [chunkSize] usable bytes.
int payloadPerPacket(int chunkSize) {
  // [chunkSize] is USABLE bytes -- what the controller reports in DFU_STATUS,
  // already net of ATT overhead. One rule at every size: a branch on the
  // magnitude would make the same number mean two different things depending
  // on how big it is.
  final payload = chunkSize - 4;
  if (payload <= 0) {
    throw ArgumentError.value(
        chunkSize, 'chunkSize', 'leaves no room for the 4-byte offset');
  }
  return payload;
}

class DfuStatus {
  const DfuStatus({
    required this.state,
    required this.received,
    required this.chunkSize,
  });

  final DfuState state;

  /// The highest **contiguous** offset the controller has written. This is the
  /// progress the screen shows: bytes handed to the OS run ahead of bytes that
  /// arrived, and would read 100% on a transfer that lost a third of itself.
  final int received;

  final int chunkSize;

  static const int kLength = 7;

  static DfuStatus? decode(List<int> bytes) {
    if (bytes.length < kLength) return null;
    final d = ByteData.sublistView(Uint8List.fromList(bytes));
    return DfuStatus(
      state: switch (d.getUint8(0)) {
        0 => DfuState.idle,
        1 => DfuState.receiving,
        2 => DfuState.verifying,
        3 => DfuState.ready,
        4 => DfuState.error,
        _ => DfuState.unknown,
      },
      received: d.getUint32(1, Endian.little),
      chunkSize: d.getUint16(5, Endian.little),
    );
  }
}
