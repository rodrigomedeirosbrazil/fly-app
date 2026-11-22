import 'package:fly_app/ble/dfu_write_limit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('nativeDfuWriteLimit', () {
    test('an MTU of 517 is capped at the 512-byte attribute limit', () {
      // Android reported mtuNow 517; the plugin refused the 514-byte packet
      // with "dataLen: 514 > max: 512 (withoutResponse)".
      expect(nativeDfuWriteLimit(517), 512);
    });

    test('an MTU of exactly 515 gives 512', () {
      expect(nativeDfuWriteLimit(515), 512);
    });

    test('a smaller MTU is MTU minus the 3-byte ATT header', () {
      expect(nativeDfuWriteLimit(185), 182);
      expect(nativeDfuWriteLimit(247), 244);
    });

    test('the 23-byte default gives 20', () {
      expect(nativeDfuWriteLimit(23), 20);
    });
  });
}
