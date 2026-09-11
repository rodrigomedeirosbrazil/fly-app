import 'dart:async';
import 'dart:typed_data';

import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/state/telemetry_source_policy.dart';

/// A minimal valid binary frame: struct version 1, armed/disarmed, all three
/// signals Valid, 87 % coulomb SoC, a configurable flight clock and battery mv.
Uint8List binarySample({
  int ver = 1,
  int sessionSec = 754,
  bool armed = true,
  int batteryMv = 50400,
}) {
  final d = ByteData(56);
  d.setUint8(0, ver);
  d.setUint8(1, armed ? 0x01 : 0x00);
  d.setUint8(5, 0x3F); // motor, esc, battery all Valid
  d.setUint8(7, 87); // socCc
  d.setUint8(10, 100); // powerPct
  d.setUint16(14, batteryMv, Endian.little);
  d.setUint32(36, sessionSec, Endian.little);
  return d.buffer.asUint8List();
}

/// Stands in for the radio. Overriding the two streams is enough: everything
/// above [FlyControllerLink] is testable precisely because that class is the
/// only thing that touches hardware.
class FakeLink extends FlyControllerLink {
  final _status = StreamController<LinkStatus>.broadcast();
  final _payloads = StreamController<TelemetryPayload>.broadcast();
  final _responses = StreamController<List<int>>.broadcast();
  final commands = <List<int>>[];

  @override
  Stream<LinkStatus> get status => _status.stream;

  @override
  Stream<TelemetryPayload> get payloads => _payloads.stream;

  @override
  Stream<List<int>> get responses => _responses.stream;

  @override
  bool get canSendCommands => true;

  /// Set to fail every write, standing in for a controller with no CMD.
  bool rejectCommands = false;

  @override
  Future<void> sendCommand(List<int> bytes) async {
    if (rejectCommands) throw StateError('no CMD characteristic');
    commands.add(bytes);
  }

  /// Replies to the request at [index] with a full Thermal group.
  void replyThermal(int index, {int status = 0}) {
    final req = commands[index];
    final d = ByteData(17);
    d.setInt32(0, 80000, Endian.little);
    d.setInt32(4, 100000, Endian.little);
    d.setInt32(8, 70000, Endian.little);
    d.setInt32(12, 95000, Endian.little);
    final payload = status == 0 ? d.buffer.asUint8List() : Uint8List(0);
    _responses.add([req[0], req[1], status, payload.length, ...payload]);
  }

  /// Replies to the request at [index] with a full Power group.
  void replyPower(int index, {int status = 0}) {
    final req = commands[index];
    final d = ByteData(9);
    d.setUint16(0, 18000, Endian.little); // capacityMah
    d.setUint16(2, 44100, Endian.little); // minVoltageMv
    d.setUint16(4, 58100, Endian.little); // maxVoltageMv
    d.setUint8(6, 1); // powerControlEnabled
    d.setUint16(7, 1100, Endian.little); // voltageDividerRatio (11.00 * 100)
    final payload = status == 0 ? d.buffer.asUint8List() : Uint8List(0);
    _responses.add([req[0], req[1], status, payload.length, ...payload]);
  }

  /// Replies to the request at [index] with a full BMS group.
  void replyBms(int index, {int status = 0}) {
    final req = commands[index];
    final d = Uint8List(7);
    d[0] = 0; // bmsType: none
    // bmsMac: all zeros (unset)
    final payload = status == 0 ? d : Uint8List(0);
    _responses.add([req[0], req[1], status, payload.length, ...payload]);
  }

  /// Replies to the request at [index] with a full System group.
  void replySystem(int index, {int status = 0}) {
    final req = commands[index];
    final d = Uint8List(8);
    d[0] = 50; // buzzerVolume
    d[1] = 0; // throttleSource: wired
    // remoteMac: all zeros (unset)
    final payload = status == 0 ? d : Uint8List(0);
    _responses.add([req[0], req[1], status, payload.length, ...payload]);
  }

  /// Replies with a status and no payload.
  void replyStatus(int index, int status) {
    final req = commands[index];
    _responses.add([req[0], req[1], status, 0]);
  }

  /// Set before calling start() to simulate a precondition the pilot has to
  /// fix: a refused permission, Bluetooth off, or location off.
  LinkStatus? blocking;

  @override
  Future<LinkStatus?> blockingCondition() async => blocking;

  int connectCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls++;
    _status.add(LinkStatus.connected);
  }

  @override
  Future<void> disconnect() async => _status.add(LinkStatus.idle);

  @override
  Future<void> dispose() async {
    await _status.close();
    await _payloads.close();
    await _responses.close();
  }

  int fallbackCalls = 0;

  @override
  Future<void> fallBackToXctod() async => fallbackCalls++;

  void emit(LinkStatus s) => _status.add(s);

  void feed(String line) => _payloads.add(
        TelemetryPayload(TelemetrySource.xctod, '$line\r\n'.codeUnits),
      );

  void feedBinary(Uint8List bytes) =>
      _payloads.add(TelemetryPayload(TelemetrySource.control, bytes));
}
