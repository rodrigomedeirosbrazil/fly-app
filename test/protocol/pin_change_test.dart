import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/pin_change.dart';

void main() {
  group('checkNewPin', () {
    test('accepts 4 to 8 printable ASCII characters that match', () {
      expect(checkNewPin('1234', '1234'), isNull);
      expect(checkNewPin('abcd1234', 'abcd1234'), isNull);
    });

    test('names each problem', () {
      expect(checkNewPin('123', '123'), PinProblem.tooShort);
      expect(checkNewPin('123456789', '123456789'), PinProblem.tooLong);
      expect(checkNewPin('12çd', '12çd'), PinProblem.notAscii);
      expect(checkNewPin('1234', '1235'), PinProblem.mismatch);
    });

    test('length is judged before the match', () {
      // A pilot who typed three characters twice needs to hear about the
      // length, not that two short PINs agree.
      expect(checkNewPin('123', '12'), PinProblem.tooShort);
    });
  });

  group('encodePinChange', () {
    test('is [curLen][cur][newLen][new] as raw characters', () {
      expect(
        encodePinChange(current: '0000', next: 'ab12'),
        [4, 0x30, 0x30, 0x30, 0x30, 4, 0x61, 0x62, 0x31, 0x32],
      );
    });

    test('the longest pair fits the 32-byte request slot', () {
      expect(
        encodePinChange(current: '12345678', next: 'abcdefgh').length,
        18,
      );
    });

    test('refuses a current PIN no controller can hold', () {
      expect(
        () => encodePinChange(current: '123456789', next: '1234'),
        throwsArgumentError,
      );
    });
  });
}
