import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_info.dart';

Uint8List bytes({
  int protocolVersion = 1,
  int controllerType = 1,
  int capabilities = 0,
  String appVersion = '1.2.3',
  int length = 28,
}) {
  final d = ByteData(28);
  d.setUint8(0, protocolVersion);
  d.setUint8(1, controllerType);
  d.setUint16(2, capabilities, Endian.little);
  final out = d.buffer.asUint8List();
  // char[24], NUL-padded — never NUL-terminated by contract.
  out.setRange(4, 4 + appVersion.length, appVersion.codeUnits);
  return out.sublist(0, length);
}

void main() {
  test('a short payload is rejected', () {
    expect(ControlInfo.decode(bytes(length: 27)), isNull);
    expect(ControlInfo.decode(Uint8List(0)), isNull);
  });

  test('reads every field at its offset', () {
    final info = ControlInfo.decode(bytes(
      protocolVersion: 1,
      controllerType: 3,
      capabilities: 0x000F,
      appVersion: '2.4.1-rc1',
    ))!;

    expect(info.protocolVersion, 1);
    expect(info.controllerType, ControllerType.tmotor);
    expect(info.appVersion, '2.4.1-rc1');
  });

  test('the NUL padding is trimmed, not rendered', () {
    expect(ControlInfo.decode(bytes(appVersion: '1.0.0'))!.appVersion, '1.0.0');
  });

  test('a full-width 24-character version is not truncated', () {
    const long = '123456789012345678901234';
    expect(ControlInfo.decode(bytes(appVersion: long))!.appVersion, long);
  });

  test('controller types map, and an unknown one degrades', () {
    expect(ControlInfo.decode(bytes(controllerType: 1))!.controllerType,
        ControllerType.xag);
    expect(ControlInfo.decode(bytes(controllerType: 3))!.controllerType,
        ControllerType.tmotor);
    expect(ControlInfo.decode(bytes(controllerType: 9))!.controllerType,
        ControllerType.unknown);
  });

  test('capability bits unpack', () {
    final none = ControlInfo.decode(bytes(capabilities: 0))!;
    expect(none.hasCanTelemetry, isFalse);
    expect(none.hasVoltageSensor, isFalse);
    expect(none.hasSelectableMotorTempSource, isFalse);
    expect(none.hasRemoteLink, isFalse);

    final all = ControlInfo.decode(bytes(capabilities: 0x000F))!;
    expect(all.hasCanTelemetry, isTrue);
    expect(all.hasVoltageSensor, isTrue);
    expect(all.hasSelectableMotorTempSource, isTrue);
    expect(all.hasRemoteLink, isTrue);

    expect(ControlInfo.decode(bytes(capabilities: 0x0004))!
        .hasSelectableMotorTempSource, isTrue);
    expect(ControlInfo.decode(bytes(capabilities: 0x0004))!.hasCanTelemetry,
        isFalse);
  });

  test('a protocol version newer than this app is not a decode failure', () {
    // The gate for telemetry is the frame's own `ver`, not this. A bump here
    // can mean a new config opcode, which the panel does not care about.
    final info = ControlInfo.decode(bytes(protocolVersion: 7))!;
    expect(info.protocolVersion, 7);
  });

  group('the build stamp rides on the end, under the append rule', () {
    /// A payload carrying the appended build stamp.
    Uint8List withStamp({
      String date = 'Sep 12 2026',
      String time = '12:46:03',
      int? length,
    }) {
      final out = Uint8List(ControlInfo.kLengthWithBuildStamp);
      out.setRange(0, 28, bytes());
      out.setRange(28, 28 + date.length, date.codeUnits);
      out.setRange(40, 40 + time.length, time.codeUnits);
      return length == null ? out : out.sublist(0, length);
    }

    test('it is read when the firmware sends it', () {
      final info = ControlInfo.decode(withStamp())!;

      expect(info.buildDate, 'Sep 12 2026');
      expect(info.buildTime, '12:46:03');
      // The fields ahead of it must not have moved.
      expect(info.appVersion, '1.2.3');
      expect(info.protocolVersion, 1);
    });

    test('firmware that does not send it still decodes', () {
      // Every controller built before the field existed. 28 bytes is the
      // minimum, not the size -- treating the absence as a malformed payload
      // would drop the whole control service back to `$XCTOD` over a support
      // line.
      final info = ControlInfo.decode(bytes())!;

      expect(info.buildDate, isNull);
      expect(info.buildTime, isNull);
      expect(info.appVersion, '1.2.3');
    });

    test('a stamp the firmware left blank is absent, not empty', () {
      // The field is there and unfilled. Reported as nothing to show rather
      // than as a blank line the pilot reads as a failed fetch.
      final info = ControlInfo.decode(withStamp(date: '', time: ''))!;

      expect(info.buildDate, isNull);
      expect(info.buildTime, isNull);
    });

    test('a payload that stops mid-stamp keeps what it completed', () {
      // Truncated between the two fields. The date is whole and the time is
      // not there at all, which is exactly what a partial read looks like --
      // and neither invalidates the 28 bytes ahead of them.
      final info = ControlInfo.decode(withStamp(length: 40))!;

      expect(info.buildDate, 'Sep 12 2026');
      expect(info.buildTime, isNull);
      expect(info.appVersion, '1.2.3');
    });
  });
}
