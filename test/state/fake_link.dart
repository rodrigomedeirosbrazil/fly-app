import 'dart:async';
import 'dart:typed_data';

import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/protocol/control_info.dart';
import 'package:fly_app/protocol/log_protocol.dart';
import 'package:fly_app/protocol/set_time.dart';
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

  /// `SET_TIME` writes, kept out of [commands] on purpose: tests answer
  /// config requests by their index in [commands], and a clock sync landing
  /// between them would shift every index for a reason unrelated to what
  /// those tests check.
  final clockCommands = <List<int>>[];

  /// The status [sendCommand] answers a `SET_TIME` with, or null to leave it
  /// unanswered. Answering by default matters in widget tests: an unanswered
  /// request leaves the session's timeout timer pending.
  int? clockReplyStatus = 0;

  /// Log files the fake controller holds, or null for firmware without the
  /// log opcodes (requests then go to [commands] unanswered, like any other).
  /// Answered here, like SET_TIME, so the config tests' indices into
  /// [commands] are untouched.
  Map<String, List<int>>? logFiles;
  final logCommands = <List<int>>[];

  final dfuWrites = <List<int>>[];

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

  /// Set to true to simulate a controller with DFU support.
  bool supportsDfu = false;

  @override
  bool get canUpdateFirmware => supportsDfu;

  /// What INFO reported, or null for the `$XCTOD` path where it was never
  /// read. The real link fills this at discovery from the characteristic;
  /// here it is set directly, so the repository's support-line getters have
  /// a seam at all.
  ControlInfo? fakeInfo;

  @override
  ControlInfo? get info => fakeInfo;

  @override
  Future<void> sendCommand(List<int> bytes) async {
    if (rejectCommands) throw StateError('no CMD characteristic');
    if (bytes[0] == kOpSetTime) {
      clockCommands.add(bytes);
      final status = clockReplyStatus;
      // Timer.run, not a direct add: the session installs its timeout timer
      // only after this write returns, and a reply that beat it would leave
      // that timer orphaned and pending.
      if (status != null) {
        Timer.run(() => _responses.add([bytes[0], bytes[1], status, 0]));
      }
      return;
    }
    final files = logFiles;
    if (files != null && (bytes[0] == kOpLogList || bytes[0] == kOpLogRead)) {
      logCommands.add(bytes);
      final reply = bytes[0] == kOpLogList
          ? _logListReply(files)
          : _logReadReply(files, bytes.sublist(3));
      Timer.run(() => _responses.add([bytes[0], bytes[1], 0, reply.length, ...reply]));
      return;
    }
    commands.add(bytes);
  }

  /// One page with every file, ascending, as the firmware pages them.
  List<int> _logListReply(Map<String, List<int>> files) {
    final names = files.keys.toList()..sort();
    final used = files.values.fold<int>(0, (a, b) => a + b.length);
    final head = ByteData(12)
      ..setUint32(0, used, Endian.little)
      ..setUint32(4, 131072, Endian.little)
      ..setUint16(8, names.length, Endian.little)
      ..setUint8(10, 0)
      ..setUint8(11, names.length);
    final out = [...head.buffer.asUint8List()];
    for (final n in names) {
      final s = ByteData(4)..setUint32(0, files[n]!.length, Endian.little);
      out
        ..addAll(s.buffer.asUint8List())
        ..add(n.length)
        ..addAll(n.codeUnits);
    }
    return out;
  }

  List<int> _logReadReply(Map<String, List<int>> files, List<int> p) {
    final d = ByteData.sublistView(Uint8List.fromList(p));
    final offset = d.getUint32(0, Endian.little);
    final maxLen = p[4];
    final name = String.fromCharCodes(p.sublist(6, 6 + p[5]));
    final data = files[name] ?? const <int>[];
    final end = (offset + maxLen).clamp(0, data.length);
    final head = ByteData(8)
      ..setUint32(0, offset, Endian.little)
      ..setUint32(4, data.length, Endian.little);
    return [...head.buffer.asUint8List(), ...data.sublist(offset, end)];
  }

  @override
  Future<void> writeDfuData(List<int> bytes) async {
    if (!supportsDfu) throw StateError('no DFU data characteristic');
    dfuWrites.add(bytes);
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

  /// Pushes a raw response frame for testing unsolicited events.
  void pushResponse(List<int> frame) {
    _responses.add(frame);
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
