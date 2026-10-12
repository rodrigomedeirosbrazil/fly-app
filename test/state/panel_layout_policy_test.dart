import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_info.dart';
import 'package:fly_app/state/panel_layout_policy.dart';

void main() {
  group('bottomRowFor', () {
    for (final (type, bms, expected) in const [
      (ControllerType.tmotor, false, BottomRowLayout.full),
      (ControllerType.tmotor, true, BottomRowLayout.full),
      (ControllerType.xag, true, BottomRowLayout.noRpm),
      (ControllerType.xag, false, BottomRowLayout.voltageOnly),
      // The sentence path cannot say which board it is. Every card stays and
      // an absent reading shows its dash, rather than guessing a layout.
      (ControllerType.unknown, false, BottomRowLayout.full),
      (ControllerType.unknown, true, BottomRowLayout.full),
    ]) {
      test('$type with BMS $bms is $expected', () {
        expect(bottomRowFor(type: type, bmsConfigured: bms), expected);
      });
    }
  });

  test('the ESC temperature source follows the board', () {
    expect(escTempSourceFor(ControllerType.tmotor), 'CAN');
    expect(escTempSourceFor(ControllerType.xag), 'NTC');
    expect(escTempSourceFor(ControllerType.unknown), isNull);
  });
}
