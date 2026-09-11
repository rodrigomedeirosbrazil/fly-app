import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/mac_address.dart';

void main() {
  group('formatMac', () {
    test('renders six bytes upper case, colon separated', () {
      expect(formatMac([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]),
          'AA:BB:CC:DD:EE:FF');
    });

    test('pads a byte below 0x10', () {
      expect(formatMac([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
          '01:02:03:04:05:06');
    });

    test('all zero is unset, not an address', () {
      expect(formatMac([0, 0, 0, 0, 0, 0]), isNull);
    });

    test('the wrong length is not an address', () {
      expect(formatMac([1, 2, 3]), isNull);
      expect(formatMac([1, 2, 3, 4, 5, 6, 7]), isNull);
    });
  });

  group('parseMac', () {
    test('round trips', () {
      expect(parseMac('AA:BB:CC:DD:EE:FF'),
          [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
    });

    test('accepts lower case and surrounding space', () {
      expect(parseMac(' aa:bb:cc:dd:ee:ff '),
          [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
    });

    test('rejects anything that is not six hex pairs', () {
      expect(parseMac('AA:BB:CC:DD:EE'), isNull);
      expect(parseMac('AA:BB:CC:DD:EE:FF:00'), isNull);
      expect(parseMac('AA-BB-CC-DD-EE-FF'), isNull);
      expect(parseMac('ZZ:BB:CC:DD:EE:FF'), isNull);
      expect(parseMac('AABBCCDDEEFF'), isNull);
      expect(parseMac(''), isNull);
    });
  });

  test('kUnsetMac is six zeroes', () {
    expect(kUnsetMac, [0, 0, 0, 0, 0, 0]);
    expect(isUnsetMac(kUnsetMac), isTrue);
    expect(isUnsetMac([0, 0, 0, 0, 0, 1]), isFalse);
  });
}
