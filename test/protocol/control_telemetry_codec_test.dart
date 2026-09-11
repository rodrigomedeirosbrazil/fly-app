import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_telemetry_codec.dart';
import 'package:fly_app/protocol/telemetry_frame.dart';

/// Builds a wire-shaped 56-byte struct. Every setter here is an offset
/// assertion: if the firmware moves a field, this helper is what has to
/// change, and every test that leans on it fails at once.
Uint8List bytes({
  int ver = 1,
  int flags = 0,
  int validity = 0,
  int disarmReason = 0,
  int signalStates = 0,
  int motorTempSrc = 0,
  int socCc = 0,
  int socVolt = 0,
  int throttlePct = 0,
  int powerPct = 100,
  int powerScale = 0,
  int armCharge = 0,
  int limitCauses = 0,
  int batteryMv = 0,
  int throttleRaw = 0,
  int powerKwX10 = 0,
  int escCurrentMa = 0,
  int rpm = 0,
  int motorTempMc = 0,
  int escTempMc = 0,
  int sessionSec = 0,
  int hourMeterSec = 0,
  int cellMinMv = 0,
  int cellMaxMv = 0,
  int cellDeltaMv = 0,
  int bmsTempMaxC = 0,
  int uptimeSec = 0,
  int length = 56,
}) {
  final d = ByteData(56);
  d.setUint8(0, ver);
  d.setUint8(1, flags);
  d.setUint16(2, validity, Endian.little);
  d.setUint8(4, disarmReason);
  d.setUint8(5, signalStates);
  d.setUint8(6, motorTempSrc);
  d.setUint8(7, socCc);
  d.setUint8(8, socVolt);
  d.setUint8(9, throttlePct);
  d.setUint8(10, powerPct);
  d.setUint8(11, powerScale);
  d.setUint8(12, armCharge);
  d.setUint8(13, limitCauses);
  d.setUint16(14, batteryMv, Endian.little);
  d.setUint16(16, throttleRaw, Endian.little);
  d.setUint16(18, powerKwX10, Endian.little);
  d.setInt32(20, escCurrentMa, Endian.little);
  d.setUint32(24, rpm, Endian.little);
  d.setInt32(28, motorTempMc, Endian.little);
  d.setInt32(32, escTempMc, Endian.little);
  d.setUint32(36, sessionSec, Endian.little);
  d.setUint32(40, hourMeterSec, Endian.little);
  d.setUint16(44, cellMinMv, Endian.little);
  d.setUint16(46, cellMaxMv, Endian.little);
  d.setUint16(48, cellDeltaMv, Endian.little);
  d.setInt16(50, bmsTempMaxC, Endian.little);
  d.setUint32(52, uptimeSec, Endian.little);
  return d.buffer.asUint8List().sublist(0, length);
}

final at = DateTime.utc(2026, 9, 11);

TelemetryFrame decode(Uint8List b) {
  final f = ControlTelemetryCodec.decode(b, receivedAt: at);
  expect(f, isNotNull, reason: 'expected this frame to decode');
  return f!;
}

/// All three signals Valid. 0b11_11_11 in bits 5..0.
const allValid = 0x3F;

void main() {
  group('rejection', () {
    test('a packet shorter than 56 bytes is rejected whole', () {
      expect(
        ControlTelemetryCodec.decode(bytes(length: 55), receivedAt: at),
        isNull,
      );
      expect(
        ControlTelemetryCodec.decode(bytes(length: 20), receivedAt: at),
        isNull,
      );
      expect(ControlTelemetryCodec.decode(Uint8List(0), receivedAt: at), isNull);
    });

    test('an unknown struct version is rejected, not decoded hopefully', () {
      expect(ControlTelemetryCodec.decode(bytes(ver: 2), receivedAt: at), isNull);
      expect(ControlTelemetryCodec.decode(bytes(ver: 0), receivedAt: at), isNull);
    });

    test('a longer packet decodes its first 56 bytes and ignores the tail', () {
      final padded = Uint8List(72)..setRange(0, 56, bytes(socCc: 87));
      final f = decode(padded);
      expect(f.socCoulomb, 87);
    });
  });

  group('offsets and endianness', () {
    test('every scalar lands where the header says it does', () {
      final f = decode(bytes(
        flags: 0x01,
        validity: 0x001F,
        signalStates: allValid,
        motorTempSrc: 1,
        socCc: 87,
        socVolt: 91,
        throttlePct: 42,
        powerPct: 80,
        limitCauses: 0x02,
        batteryMv: 50400,
        throttleRaw: 1234,
        powerKwX10: 15,
        escCurrentMa: 30000,
        rpm: 4200,
        motorTempMc: 61500,
        escTempMc: 54250,
        sessionSec: 754,
        hourMeterSec: 123456,
        cellMinMv: 3712,
        cellMaxMv: 3745,
        cellDeltaMv: 33,
        bmsTempMaxC: 38,
        uptimeSec: 900,
      ));

      expect(f.isArmed, isTrue);
      expect(f.socCoulomb, 87);
      expect(f.socVoltage, 91);
      expect(f.throttlePct, 42);
      expect(f.powerPct, 80);
      expect(f.throttleRaw, 1234);
      expect(f.motorTempSource, MotorTempSource.can);
      expect(f.voltage, closeTo(50.4, 1e-9));
      expect(f.powerKw, closeTo(1.5, 1e-9));
      expect(f.currentA, closeTo(30.0, 1e-9));
      expect(f.rpm, 4200);
      expect(f.motorTempC, closeTo(61.5, 1e-9));
      expect(f.escTempC, closeTo(54.25, 1e-9));
      expect(f.sessionSec, const Duration(seconds: 754));
      expect(f.hourMeterSec, const Duration(seconds: 123456));
      expect(f.uptimeSec, const Duration(seconds: 900));
      expect(f.cellMinMv, 3712);
      expect(f.cellMaxMv, 3745);
      expect(f.cellDeltaMv, 33);
      expect(f.bmsMaxTempC, 38);
    });

    test('signed fields survive their sign', () {
      final f = decode(bytes(
        validity: 0x0009,
        signalStates: allValid,
        escCurrentMa: -12500,
        motorTempMc: -5250,
        escTempMc: -10000,
        bmsTempMaxC: -7,
      ));
      expect(f.currentA, closeTo(-12.5, 1e-9), reason: 'regen is legitimate');
      expect(f.motorTempC, closeTo(-5.25, 1e-9));
      expect(f.escTempC, closeTo(-10.0, 1e-9));
      expect(f.bmsMaxTempC, -7);
    });

    test('the motor temp source is mapped, never indexed', () {
      // Firmware MotorTempOrigin is {None = 0, Can = 1, Ntc = 2}; the Dart
      // enum is declared {can, ntc, none}. Indexing one by the other silently
      // swaps CAN and NTC.
      expect(decode(bytes(motorTempSrc: 0)).motorTempSource,
          MotorTempSource.none);
      expect(decode(bytes(motorTempSrc: 1)).motorTempSource,
          MotorTempSource.can);
      expect(decode(bytes(motorTempSrc: 2)).motorTempSource,
          MotorTempSource.ntc);
      expect(decode(bytes(motorTempSrc: 9)).motorTempSource,
          MotorTempSource.none,
          reason: 'an unknown source drops the badge, never the whole frame');
    });
  });

  group('validity bits decide availability', () {
    test('a clear bit nulls its reading rather than reporting zero', () {
      final f = decode(bytes(
        validity: 0,
        escCurrentMa: 30000,
        rpm: 4200,
        powerKwX10: 15,
        cellMinMv: 3712,
        cellMaxMv: 3745,
        cellDeltaMv: 33,
        bmsTempMaxC: 38,
      ));
      expect(f.currentA, isNull);
      expect(f.rpm, isNull);
      expect(f.powerKw, isNull);
      expect(f.bmsMaxTempC, isNull);
      expect(f.cellMinMv, isNull);
      expect(f.cellMaxMv, isNull);
      expect(f.cellDeltaMv, isNull);
    });

    test('each bit frees exactly its own reading', () {
      expect(decode(bytes(validity: 0x0001, escCurrentMa: 1000)).currentA,
          closeTo(1.0, 1e-9));
      expect(decode(bytes(validity: 0x0002, rpm: 10)).rpm, 10);
      expect(decode(bytes(validity: 0x0004, powerKwX10: 20)).powerKw,
          closeTo(2.0, 1e-9));
      expect(decode(bytes(validity: 0x0008, bmsTempMaxC: 38)).bmsMaxTempC, 38);
      expect(decode(bytes(validity: 0x0010, cellMinMv: 3712)).cellMinMv, 3712);
    });

    test('BMS temperature and per-cell data are separate bits', () {
      final f = decode(bytes(validity: 0x0008, bmsTempMaxC: 38, cellMinMv: 3712));
      expect(f.bmsMaxTempC, 38);
      expect(f.cellMinMv, isNull, reason: 'per-cell needs its own bit');
    });
  });

  group('signal states decide health', () {
    // packSignalStates: motor in bits 5-4, esc in 3-2, battery in 1-0.
    int pack(int motor, int esc, int batt) =>
        ((motor & 3) << 4) | ((esc & 3) << 2) | (batt & 3);

    test('only Valid produces a number', () {
      for (final state in [0, 1, 2]) {
        final f = decode(bytes(
          signalStates: pack(state, state, state),
          motorTempMc: 61000,
          escTempMc: 54000,
          batteryMv: 50400,
        ));
        expect(f.motorTempC, isNull, reason: 'state $state is not Valid');
        expect(f.escTempC, isNull, reason: 'state $state is not Valid');
        expect(f.voltage, isNull, reason: 'state $state is not Valid');
      }
    });

    test('zero is a legitimate reading when the state says Valid', () {
      final f = decode(bytes(
        signalStates: allValid,
        motorTempMc: 0,
        escTempMc: 0,
        batteryMv: 0,
      ));
      expect(f.motorTempC, 0.0, reason: 'a cold motor is not a missing sensor');
      expect(f.escTempC, 0.0);
      expect(f.voltage, 0.0);
    });

    test('the state itself is carried, not just its consequence', () {
      final f = decode(bytes(signalStates: pack(1, 2, 3)));
      expect(f.motorTempState, SignalState.stale);
      expect(f.escTempState, SignalState.invalid);
      expect(f.batteryVoltageState, SignalState.valid);
    });

    test('each signal reads its own two bits', () {
      final f = decode(bytes(
        signalStates: pack(3, 0, 0),
        motorTempMc: 61000,
        escTempMc: 54000,
        batteryMv: 50400,
      ));
      expect(f.motorTempC, closeTo(61.0, 1e-9));
      expect(f.escTempC, isNull);
      expect(f.voltage, isNull);
    });

    test('socVoltage follows the battery-voltage state', () {
      expect(decode(bytes(signalStates: pack(0, 0, 3), socVolt: 91)).socVoltage,
          91);
      expect(decode(bytes(signalStates: pack(0, 0, 1), socVolt: 91)).socVoltage,
          isNull,
          reason: 'a SoC derived from a reading the firmware distrusts');
    });

    test('socCoulomb is always present: it has no validity concept', () {
      final f = decode(bytes(signalStates: 0, socCc: 87));
      expect(f.socCoulomb, 87);
    });
  });

  group('flags, causes and disarm reasons', () {
    test('flags unpack to their booleans', () {
      final f = decode(bytes(flags: 0x3F));
      expect(f.isArmed, isTrue);
      expect(f.isEngaged, isTrue);
      expect(f.hasTelemetry, isTrue);
      expect(f.powerControlEnabled, isTrue);
      expect(f.bmsConnected, isTrue);
      expect(f.bmsConfigured, isTrue);

      final off = decode(bytes(flags: 0));
      expect(off.isArmed, isFalse);
      expect(off.bmsConnected, isFalse);
    });

    test('no limiter is an empty set, never null', () {
      final f = decode(bytes(limitCauses: 0));
      expect(f.limitCauses, isEmpty);
      expect(f.limitCauses, isNotNull,
          reason: 'null would mean the source cannot say');
    });

    test('causes combine', () {
      expect(decode(bytes(limitCauses: 0x01)).limitCauses,
          {LimitCause.battery});
      expect(decode(bytes(limitCauses: 0x02)).limitCauses,
          {LimitCause.motorTemp});
      expect(decode(bytes(limitCauses: 0x04)).limitCauses,
          {LimitCause.escTemp});
      expect(decode(bytes(limitCauses: 0x07)).limitCauses, {
        LimitCause.battery,
        LimitCause.motorTemp,
        LimitCause.escTemp,
      });
    });

    test('every firmware disarm reason maps by position', () {
      const expected = [
        DisarmReason.none,
        DisarmReason.manual,
        DisarmReason.throttleWiredInvalid,
        DisarmReason.throttleLinkLost,
        DisarmReason.motorTempLost,
        DisarmReason.escTempLost,
        DisarmReason.batteryVoltageLost,
        DisarmReason.motorTempSourceChanged,
      ];
      for (var i = 0; i < expected.length; i++) {
        expect(decode(bytes(disarmReason: i)).disarmReason, expected[i],
            reason: 'reason $i');
      }
    });

    test('a reason from a newer firmware degrades instead of throwing', () {
      expect(decode(bytes(disarmReason: 99)).disarmReason, DisarmReason.unknown);
    });

    test('a fault shows its code while disarmed', () {
      final f = decode(bytes(flags: 0, disarmReason: 7));
      expect(f.disarmCode, 'MOT SRC');
    });
  });

  test('receivedAt is the app clock, never anything on the wire', () {
    expect(decode(bytes()).receivedAt, at);
  });
}
