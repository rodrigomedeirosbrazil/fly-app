import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/set_time.dart';

void main() {
  test('the opcode is 0x27', () {
    expect(kOpSetTime, 0x27);
  });

  test('encodes epoch milliseconds as int64 little-endian', () {
    // 0x0199A1B2C3D4 ms, chosen so the low five bytes all differ: a
    // big-endian or 32-bit encoding cannot produce this sequence by accident.
    final t = DateTime.fromMillisecondsSinceEpoch(1759354471380, isUtc: true);
    expect(encodeSetTime(t), [0xD4, 0xC3, 0xB2, 0xA1, 0x99, 0x01, 0x00, 0x00]);
  });

  test('is always eight bytes', () {
    expect(encodeSetTime(DateTime.utc(2026, 10, 2)), hasLength(8));
  });

  test("the phone's time zone does not change the bytes", () {
    // Epoch milliseconds are UTC by definition, and the firmware formats
    // with gmtime_r. A local DateTime and its UTC twin are the same instant.
    final utc = DateTime.utc(2026, 10, 2, 15, 30);
    expect(encodeSetTime(utc.toLocal()), encodeSetTime(utc));
  });
}
