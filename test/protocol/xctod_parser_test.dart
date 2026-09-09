import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/xctod_frame.dart';
import 'package:fly_app/protocol/xctod_parser.dart';

/// Tmotor build, every sensor healthy, armed and flying.
const healthy =
    r'$XCTOD,87,91,50.400,1.5,42,1234,100,61,can,4200,30,54,ARMED,38,3712,3745';

/// XAG build: no current sensing, no motor temp, no BMS, disarmed by a
/// battery-voltage fault.
const degraded = r'$XCTOD,64,64,48.100,,0,812,100,,,,,44,BATT ERR,,,';

final t0 = DateTime.utc(2026, 9, 9, 12, 0, 0);

void main() {
  group('healthy frame', () {
    test('decodes every field', () {
      final f = XctodParser.parse(healthy, receivedAt: t0)!;

      expect(f.socCoulomb, 87);
      expect(f.socVoltage, 91);
      expect(f.voltage, 50.4);
      expect(f.powerKw, 1.5);
      expect(f.throttlePct, 42);
      expect(f.throttleRaw, 1234);
      expect(f.powerPct, 100);
      expect(f.motorTempC, 61);
      expect(f.motorTempSource, MotorTempSource.can);
      expect(f.rpm, 4200);
      expect(f.currentA, 30);
      expect(f.escTempC, 54);
      expect(f.armState, ArmState.armed);
      expect(f.disarmCode, isNull);
      expect(f.bmsMaxTempC, 38);
      expect(f.cellMinMv, 3712);
      expect(f.cellMaxMv, 3745);
      expect(f.receivedAt, t0);
      expect(f.isLimited, isFalse);
    });
  });

  group('degraded frame', () {
    test('maps empty fields to null, never to zero', () {
      final f = XctodParser.parse(degraded, receivedAt: t0)!;

      expect(f.powerKw, isNull);
      expect(f.motorTempC, isNull);
      expect(f.motorTempSource, MotorTempSource.none);
      expect(f.rpm, isNull);
      expect(f.currentA, isNull);
      expect(f.bmsMaxTempC, isNull);
      expect(f.cellMinMv, isNull);
      expect(f.cellMaxMv, isNull);
    });

    test('keeps the fields that are still present', () {
      final f = XctodParser.parse(degraded, receivedAt: t0)!;

      expect(f.voltage, 48.1);
      expect(f.escTempC, 44);
      expect(f.throttleRaw, 812);
    });

    test('surfaces the disarm code', () {
      final f = XctodParser.parse(degraded, receivedAt: t0)!;

      expect(f.armState, ArmState.disarmed);
      expect(f.disarmCode, 'BATT ERR');
    });
  });

  group('status field', () {
    XctodFrame parseStatus(String status) {
      final line = healthy.replaceFirst('ARMED', status);
      return XctodParser.parse(line, receivedAt: t0)!;
    }

    test('plain DISARMED carries no code', () {
      final f = parseStatus('DISARMED');
      expect(f.armState, ArmState.disarmed);
      expect(f.disarmCode, isNull);
    });

    for (final code in const [
      'THR ERR',
      'LINK ERR',
      'MOT ERR',
      'ESC ERR',
      'BATT ERR',
      'MOT SRC',
    ]) {
      test('$code is a disarm code', () {
        final f = parseStatus(code);
        expect(f.armState, ArmState.disarmed);
        expect(f.disarmCode, code);
      });
    }
  });

  group('motor temp source', () {
    test('ntc is recognised', () {
      final line = healthy.replaceFirst(',can,', ',ntc,');
      expect(
        XctodParser.parse(line, receivedAt: t0)!.motorTempSource,
        MotorTempSource.ntc,
      );
    });

    test('an unknown source degrades to none instead of killing the frame', () {
      final line = healthy.replaceFirst(',can,', ',pt100,');
      final f = XctodParser.parse(line, receivedAt: t0);
      expect(f, isNotNull);
      expect(f!.motorTempSource, MotorTempSource.none);
      expect(f.motorTempC, 61);
    });
  });

  group('rejection', () {
    test('rejects a truncated line', () {
      // What a 20-byte notification looks like when the MTU never grew.
      expect(XctodParser.parse(r'$XCTOD,87,91,50.400,', receivedAt: t0), isNull);
    });

    test('rejects too many fields', () {
      expect(XctodParser.parse('$healthy,99', receivedAt: t0), isNull);
    });

    test('rejects a line without the prefix', () {
      final line = healthy.replaceFirst(r'$XCTOD', r'$GPGGA');
      expect(XctodParser.parse(line, receivedAt: t0), isNull);
    });

    test('rejects garbage in a numeric field', () {
      final line = healthy.replaceFirst(',4200,', ',4x00,');
      expect(XctodParser.parse(line, receivedAt: t0), isNull);
    });

    test('rejects an empty always-present field', () {
      // throttle_pct is never empty in a well-formed frame.
      final line = healthy.replaceFirst(',42,1234,', ',,1234,');
      expect(XctodParser.parse(line, receivedAt: t0), isNull);
    });

    test('tolerates trailing CR LF', () {
      expect(
        XctodParser.parse('$healthy\r\n', receivedAt: t0),
        isNotNull,
      );
    });
  });

  test('powerPct below 100 marks the frame as limited', () {
    final line = healthy.replaceFirst(',1234,100,', ',1234,73,');
    expect(XctodParser.parse(line, receivedAt: t0)!.isLimited, isTrue);
  });
}
