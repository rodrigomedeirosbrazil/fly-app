import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/control_frame.dart';
import 'package:fly_app/protocol/dfu_protocol.dart' as dfu_protocol;
import 'package:fly_app/state/control_session.dart';
import 'package:fly_app/state/dfu_session.dart';

class FakeDfuTransport implements DfuTransport {
  final requestLog = <({int op, List<int> payload})>[];
  final writeDataLog = <List<int>>[];
  final _requestQueue = <ControlResult>[];

  void queueOk([List<int> payload = const []]) {
    _requestQueue.add(ControlOk(payload));
  }

  void queueRefused(ControlStatus status) {
    _requestQueue.add(ControlRefused(status));
  }

  void queueTimeout() {
    _requestQueue.add(const ControlTimeout());
  }

  void queueDropped() {
    _requestQueue.add(const ControlDropped());
  }

  /// Queue a DFU_STATUS response with given state, received bytes, and chunk size.
  void queueDfuStatus({
    required dfu_protocol.DfuState state,
    required int received,
    int chunkSize = 244,
  }) {
    final d = ByteData(7);
    d.setUint8(0, _dfuStateToInt(state));
    d.setUint32(1, received, Endian.little);
    d.setUint16(5, chunkSize, Endian.little);
    queueOk(d.buffer.asUint8List().toList());
  }

  int _dfuStateToInt(dfu_protocol.DfuState state) => switch (state) {
    dfu_protocol.DfuState.idle => 0,
    dfu_protocol.DfuState.receiving => 1,
    dfu_protocol.DfuState.verifying => 2,
    dfu_protocol.DfuState.ready => 3,
    dfu_protocol.DfuState.error => 4,
    dfu_protocol.DfuState.unknown => 0,
  };

  @override
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) async {
    requestLog.add((op: op, payload: payload));
    if (_requestQueue.isEmpty) {
      return const ControlTimeout();
    }
    return _requestQueue.removeAt(0);
  }

  @override
  Future<void> writeData(List<int> bytes) async {
    writeDataLog.add(bytes);
  }
}

void main() {
  group('DfuSession', () {
    test('a clean transfer reaches ready', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
      );

      // Create a small image with ESP32 magic
      final image = Uint8List(1024);
      image[0] = 0xE9;

      // Setup: DFU_BEGIN ok
      transport.queueOk();

      // Setup: first status check after BEGIN
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 0,
        chunkSize: 244,
      );

      // Setup: status after data send
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 1024,
        chunkSize: 244,
      );

      // Setup: status check during verification
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.ready,
        received: 1024,
        chunkSize: 244,
      );

      await session.start(image);

      expect(session.state, DfuTransferState.ready);
      expect(session.outcome, isA<DfuReady>());
      expect(session.progress, 1.0);
      expect(session.bytesAcknowledged, 1024);
    });

    test('the whole image is sent, in order, from offset zero', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
      );

      final image = Uint8List(600);
      image[0] = 0xE9;

      // DFU_BEGIN ok
      transport.queueOk();

      // First status: ready to receive
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 0,
        chunkSize: 244,
      );

      // After data sent
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 600,
        chunkSize: 244,
      );

      // Ready
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.ready,
        received: 600,
        chunkSize: 244,
      );

      await session.start(image);

      // Check that data was written in order
      expect(transport.writeDataLog.length, greaterThan(0));

      // Collect all written bytes (skip the 4-byte offset header)
      final allBytes = <int>[];
      int expectedOffset = 0;

      for (final packet in transport.writeDataLog) {
        // First 4 bytes are offset
        final offset = ByteData.sublistView(Uint8List.fromList(packet))
            .getUint32(0, Endian.little);
        expect(offset, expectedOffset);

        // Rest are data
        final dataInPacket = packet.sublist(4);
        allBytes.addAll(dataInPacket);
        expectedOffset += dataInPacket.length;
      }

      // Verify we sent the whole image
      expect(allBytes.length, 600);
      expect(allBytes.sublist(0, 1)[0], 0xE9);
    });

    test('a short count restarts from what the controller acknowledged',
        () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
        maxRestarts: 3,
      );

      final image = Uint8List(2400);
      image[0] = 0xE9;

      // DFU_BEGIN ok
      transport.queueOk();

      // First status: ready to receive
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 0,
        chunkSize: 244,
      );

      // After sending all: short count (1000 of 2400)
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 1000,
        chunkSize: 244,
      );

      // Stuck check: still 1000 (triggers restart)
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 1000,
        chunkSize: 244,
      );

      // After restart from 1000: full count
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 2400,
        chunkSize: 244,
      );

      // Ready
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.ready,
        received: 2400,
        chunkSize: 244,
      );

      await session.start(image);

      // Key assertion: next packet after short count should start at 1000, not 2400 or 0
      final writesCounting = <int>[];
      for (final packet in transport.writeDataLog) {
        final offset =
            ByteData.sublistView(Uint8List.fromList(packet))
                .getUint32(0, Endian.little);
        writesCounting.add(offset);
      }

      // After the short count, we should have written from offset 1000
      expect(writesCounting, contains(1000),
          reason: 'Should restart from acknowledged bytes');
    });

    test('a transfer that never advances gives up after kMaxRestarts',
        () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
        maxRestarts: 1,
      );

      final image = Uint8List(1024);
      image[0] = 0xE9;

      // DFU_BEGIN ok
      transport.queueOk();

      // First status: ready
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 0,
        chunkSize: 244,
      );

      // After sending: reports nothing received
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 0,
        chunkSize: 244,
      );

      // Again: still nothing (this is when we detect no progress)
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 0,
        chunkSize: 244,
      );

      // We're stuck, so give up after maxRestarts attempts
      await session.start(image);

      expect(session.state, DfuTransferState.failed);
      expect(session.outcome, isA<DfuFailed>());
    });

    test('progress never exceeds what the controller acknowledged', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
      );

      final image = Uint8List(1000);
      image[0] = 0xE9;

      // DFU_BEGIN ok
      transport.queueOk();

      // First status
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 0,
        chunkSize: 244,
      );

      // After data send: controller only received half
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 500,
        chunkSize: 244,
      );

      // Ready
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.ready,
        received: 1000,
        chunkSize: 244,
      );

      await session.start(image);

      // Progress should never exceed what controller acknowledged
      expect(session.progress, lessThanOrEqualTo(1.0));
      expect(session.bytesAcknowledged, 1000);
    });

    test('DFU_BEGIN is not retried', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
      );

      final image = Uint8List(100);
      image[0] = 0xE9;

      // DFU_BEGIN times out
      transport.queueTimeout();

      await session.start(image);

      // Should fail without retrying
      expect(session.state, DfuTransferState.failed);
      expect(session.outcome, isA<DfuFailed>());

      // Count DFU_BEGIN requests (op 0x50)
      final beginRequests = transport.requestLog
          .where((r) => r.op == dfu_protocol.opDfuBegin)
          .toList();

      // Must be exactly one, not retried
      expect(beginRequests.length, 1,
          reason: 'DFU_BEGIN should not be retried on timeout');
    });

    test('armed is reported without asking for a PIN', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
      );

      final image = Uint8List(100);
      image[0] = 0xE9;

      // DFU_BEGIN refused with errState (armed)
      transport.queueRefused(ControlStatus.errState);

      await session.start(image);

      expect(session.outcome, isA<DfuRefusedArmed>());
      expect(session.state, DfuTransferState.failed);
    });

    test('ErrBadOp means this firmware has no DFU', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
      );

      final image = Uint8List(100);
      image[0] = 0xE9;

      // DFU_BEGIN refused with errBadOp
      transport.queueRefused(ControlStatus.errBadOp);

      await session.start(image);

      expect(session.outcome, isA<DfuUnsupported>());
      expect(session.state, DfuTransferState.failed);
    });

    test('a bad image never reaches the transport', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
      );

      // Image with wrong magic byte
      final badImage = Uint8List(100);
      badImage[0] = 0x7F; // Not ESP32 magic

      await session.start(badImage);

      // No requests should be sent
      expect(transport.requestLog.isEmpty, true,
          reason: 'Bad image should be rejected before sending');
      expect(session.outcome, isA<DfuRejectedImage>());
      expect(
        (session.outcome as DfuRejectedImage).problem,
        dfu_protocol.ImageProblem.notEsp32,
      );
      expect(session.state, DfuTransferState.failed);
    });

    test('abort stops the stream and sends 0x52', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 50),
      );

      final image = Uint8List(5000);
      image[0] = 0xE9;

      // Setup for a long transfer
      transport.queueOk(); // DFU_BEGIN

      // Status responses that will keep the transfer going
      for (int i = 0; i < 10; i++) {
        transport.queueDfuStatus(
          state: dfu_protocol.DfuState.receiving,
          received: i * 500,
          chunkSize: 244,
        );
      }

      // Start transfer in background
      final startFuture = session.start(image);

      // Give it a moment to start
      await Future.delayed(const Duration(milliseconds: 20));

      // Abort mid-transfer
      await session.abort();

      await startFuture;

      expect(session.state, DfuTransferState.aborted);
      expect(session.outcome, isA<DfuAborted>());

      // Check that abort was sent (op 0x52)
      final abortRequests = transport.requestLog
          .where((r) => r.op == dfu_protocol.opDfuAbort)
          .toList();
      expect(abortRequests.isNotEmpty, true,
          reason: 'Abort should send DFU_ABORT command');
    });

    test('commit is refused before the controller says ready', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 10),
      );

      // Commit when in idle state
      await session.commit();

      // No commit request should be sent
      final commitRequests = transport.requestLog
          .where((r) => r.op == dfu_protocol.opDfuCommit)
          .toList();
      expect(commitRequests.isEmpty, true,
          reason: 'Commit should not send when not ready');
    });
  });
}
