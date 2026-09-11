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
}
