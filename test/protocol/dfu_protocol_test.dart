import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/dfu_protocol.dart';

void main() {
  group('crc32', () {
    test('matches the standard vectors', () {
      // The values every CRC-32/ISO-HDLC implementation agrees on. The
      // firmware computes the same number over the same bytes, and a
      // disagreement here means every update is refused.
      expect(crc32(const []), 0x00000000);
      expect(crc32('123456789'.codeUnits), 0xCBF43926);
      expect(crc32('a'.codeUnits), 0xE8B7BE43);
    });

    test('is order sensitive', () {
      expect(crc32(const [1, 2, 3]), isNot(crc32(const [3, 2, 1])));
    });

    test('runs over a large buffer', () {
      final big = Uint8List(200000)..fillRange(0, 200000, 0x5A);
      expect(crc32(big), isA<int>());
      expect(crc32(big) & 0xFFFFFFFF, crc32(big));
    });
  });

  group('inspectImage', () {
    Uint8List image(int first, int length) =>
        Uint8List(length)..[0] = first;

    test('accepts an ESP32 application image', () {
      final r = inspectImage(image(0xE9, 1024));
      expect(r.problem, isNull);
      expect(r.sizeBytes, 1024);
      expect(r.crc32, crc32(image(0xE9, 1024)));
    });

    test('refuses a file that is not firmware', () {
      // An ESP32 image starts with 0xE9. Saying so up front beats spending a
      // minute of transfer to discover it.
      expect(inspectImage(image(0x7F, 1024)).problem, ImageProblem.notEsp32);
    });

    test('refuses an image larger than a slot', () {
      // min_spiffs.csv gives each OTA slot 0x1E0000 bytes.
      expect(inspectImage(image(0xE9, kMaxImageBytes + 1)).problem,
          ImageProblem.tooLarge);
      expect(inspectImage(image(0xE9, kMaxImageBytes)).problem, isNull);
    });

    test('refuses an empty file', () {
      expect(inspectImage(Uint8List(0)).problem, ImageProblem.empty);
    });
  });

  group('frames', () {
    test('DFU_BEGIN carries size then crc, little endian', () {
      final p = encodeDfuBegin(sizeBytes: 0x00012345, crc: 0x89ABCDEF);
      expect(p, [0x45, 0x23, 0x01, 0x00, 0xEF, 0xCD, 0xAB, 0x89]);
    });

    test('DFU_STATUS decodes state, received and chunk size', () {
      final s = DfuStatus.decode([1, 0x40, 0x0D, 0x03, 0x00, 0xF0, 0x00])!;
      expect(s.state, DfuState.receiving);
      expect(s.received, 0x0003_0D40);
      expect(s.chunkSize, 240);
    });

    test('an unknown state degrades instead of throwing', () {
      expect(DfuStatus.decode([9, 0, 0, 0, 0, 0, 0])!.state, DfuState.unknown);
    });

    test('a short status is rejected whole', () {
      expect(DfuStatus.decode([1, 0, 0]), isNull);
      expect(DfuStatus.decode(const []), isNull);
    });

    test('a data packet is its absolute offset then the bytes', () {
      final p = encodeDfuData(offset: 0x0100, bytes: const [1, 2, 3]);
      expect(p, [0x00, 0x01, 0x00, 0x00, 1, 2, 3]);
    });

    test('the payload per packet leaves room for the offset', () {
      // 247-byte MTU, 244 usable, minus the 4-byte offset.
      expect(payloadPerPacket(244), 240);
      expect(payloadPerPacket(23), 16);
    });

    test('a chunk size that cannot carry payload is refused', () {
      expect(() => payloadPerPacket(4), throwsArgumentError);
    });
  });
}
