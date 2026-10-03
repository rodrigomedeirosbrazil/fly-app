import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';
import 'package:fly_app/ui/reading_text.dart';

void main() {
  test('only a non-valid state explains a missing reading', () {
    expect(signalNote(SignalState.stale), 'DESATUALIZADO');
    expect(signalNote(SignalState.invalid), 'INVÁLIDO');
    expect(signalNote(SignalState.absent), 'SEM SENSOR');
    expect(signalNote(SignalState.valid), isNull);
    expect(signalNote(null), isNull); // the sentence path cannot say
  });

  test('every fault the firmware can latch has an explanation', () {
    for (final r in [
      DisarmReason.throttleWiredInvalid,
      DisarmReason.throttleLinkLost,
      DisarmReason.motorTempLost,
      DisarmReason.escTempLost,
      DisarmReason.batteryVoltageLost,
      DisarmReason.motorTempSourceChanged,
    ]) {
      expect(kFaultExplanations[r], isNotNull, reason: '$r');
    }
    expect(kFaultExplanations[DisarmReason.manual], isNull);
  });
}
