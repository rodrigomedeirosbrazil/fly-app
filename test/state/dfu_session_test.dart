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

  /// What authenticate() answers, and how many times it was asked.
  bool authSucceeds = true;
  final authPins = <String>[];

  @override
  Future<bool> authenticate(String pin) async {
    authPins.add(pin);
    return authSucceeds;
  }

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
    // ABORT always answers Ok and consumes nothing queued: the session sends
    // one before every attempt to clear a session a previous failure left
    // open, and making each test account for it would bury what it is about.
    if (op == dfu_protocol.opDfuAbort) return const ControlOk([]);
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

      // The final poll, and it is still `receiving` -- the firmware's only
      // markVerifying()/markReady() are both inside its DFU_COMMIT handler,
      // so a controller holding a complete image reports exactly this until
      // it is told to commit. Queueing `ready` here, as this test once did,
      // described a transition the controller cannot make on its own.
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
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
      // Stalled, NOT noAnswer. Every poll above was answered -- that is how
      // the session knows it is stuck at all. Reporting silence here is what
      // put three rounds of diagnosis on a link that was working.
      expect(
        session.outcome,
        isA<DfuFailed>().having(
            (f) => f.reason, 'reason', DfuFailureReason.stalled),
      );
    });

    test('progress never exceeds what the controller acknowledged', () async {
      // THE POINT OF THIS TEST.
      //
      // The data characteristic is written WITHOUT RESPONSE, so bytes handed
      // to the OS run ahead of bytes that arrived. Progress taken from what
      // was sent reads 100% on a transfer that lost a third of itself, and
      // the pilot commits a firmware the controller never fully received.
      //
      // So the controller here is given the whole image and never
      // acknowledges more than half. Progress must stay at half.
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 5),
        maxRestarts: 2,
      );

      final image = Uint8List(1000);
      image[0] = 0xE9;

      transport.queueOk(); // DFU_BEGIN
      // Every status says 500 of 1000, however many times it is asked.
      for (var i = 0; i < 12; i++) {
        transport.queueDfuStatus(
          state: dfu_protocol.DfuState.receiving,
          received: 500,
          chunkSize: 244,
        );
      }

      final samples = <double>[];
      session.addListener(() => samples.add(session.progress));

      await session.start(image);

      final written = transport.writeDataLog
          .fold<int>(0, (sum, p) => sum + p.length - 4);
      expect(written, greaterThanOrEqualTo(image.length),
          reason: 'the whole image was handed to the transport');

      expect(session.progress, closeTo(0.5, 1e-9),
          reason: 'the controller only ever confirmed half of it');
      expect(samples.every((p) => p <= 0.5 + 1e-9), isTrue,
          reason: 'no sample may claim more than was acknowledged');
      expect(session.bytesAcknowledged, 500);
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

    test('a refused start is not reported as armed', () async {
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

      // ErrState is NOT armed here. gateRequest() uses it for armed, but the
      // DFU handlers return the same status when Update.begin() refuses --
      // which is what a transfer left open by a previous failure looks like.
      // The screen gates armed before anything reaches this class, so
      // claiming it here sent the pilot looking for a switch already off.
      expect(session.outcome, isA<DfuNotReady>());
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

  group('authentication', () {
    test('a connection with no session is told to ask for the PIN', () async {
      // THE BUG THIS COVERS.
      //
      // DFU_BEGIN is a write by the firmware's gate -- opRequiresAuth exempts
      // only DFU_STATUS -- so the FIRST transfer of every connection came
      // back ErrAuth. It was mapped to a bare DfuFailed, and the screen said
      // "Falha na transferência": the one message the pilot ever saw, for the
      // one cause with an obvious fix.
      final transport = FakeDfuTransport();
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      transport.queueRefused(ControlStatus.errAuth);

      final image = Uint8List(512)..[0] = 0xE9;
      await session.start(image);

      expect(session.outcome, isA<DfuNeedsPin>());
      expect(transport.writeDataLog, isEmpty,
          reason: 'not one byte goes out before the controller accepts');
    });

    test('a PIN authenticates before DFU_BEGIN', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      transport.queueOk();  // DFU_BEGIN, once authenticated

      final image = Uint8List(512)..[0] = 0xE9;
      await session.start(image, pin: '1234');

      expect(transport.authPins, ['1234']);
      expect(session.outcome, isNot(isA<DfuNeedsPin>()));
    });

    test('a wrong PIN says so and sends nothing', () async {
      final transport = FakeDfuTransport()..authSucceeds = false;
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      final image = Uint8List(512)..[0] = 0xE9;
      await session.start(image, pin: '9999');

      expect(session.outcome, isA<DfuWrongPin>());
      expect(transport.requestLog, isEmpty,
          reason: 'DFU_BEGIN erases a slot; it must not be reached');
    });

    test('each refusal names itself', () async {
      for (final (status, matcher) in [
        (ControlStatus.errBadArg, isA<DfuFailed>()),
        (ControlStatus.errBusy, isA<DfuFailed>()),
        (ControlStatus.errState, isA<DfuNotReady>()),
        (ControlStatus.errBadOp, isA<DfuUnsupported>()),
      ]) {
        final transport = FakeDfuTransport()..queueRefused(status);
        final session = DfuSession(transport,
            pollInterval: const Duration(milliseconds: 5));

        await session.start(Uint8List(512)..[0] = 0xE9);
        expect(session.outcome, matcher, reason: '$status');
        session.dispose();
      }
    });

    test('ErrBadArg and ErrBusy are different reasons, not one failure',
        () async {
      final bad = FakeDfuTransport()..queueRefused(ControlStatus.errBadArg);
      final busy = FakeDfuTransport()..queueRefused(ControlStatus.errBusy);
      final s1 = DfuSession(bad, pollInterval: const Duration(milliseconds: 5));
      final s2 = DfuSession(busy, pollInterval: const Duration(milliseconds: 5));
      addTearDown(s1.dispose);
      addTearDown(s2.dispose);

      await s1.start(Uint8List(512)..[0] = 0xE9);
      await s2.start(Uint8List(512)..[0] = 0xE9);

      expect((s1.outcome as DfuFailed).reason, DfuFailureReason.rejected);
      expect((s2.outcome as DfuFailed).reason, DfuFailureReason.busy);
    });
  });

  group('windowing', () {
    test('progress moves before the whole image has been sent', () async {
      // THE REGRESSION THIS COVERS.
      //
      // The first version sent every packet before asking the controller
      // anything, so the bar sat at 0% for minutes on the aircraft and then
      // jumped. Progress must move during the transfer, not after it.
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 5),
        windowBytes: 256,
        packetGap: Duration.zero,
      );
      addTearDown(session.dispose);

      final image = Uint8List(1024)..[0] = 0xE9;

      transport.queueOk();                                   // DFU_BEGIN
      transport.queueDfuStatus(
          state: dfu_protocol.DfuState.receiving, received: 0, chunkSize: 68);
      for (final n in [256, 512, 768, 1024]) {
        transport.queueDfuStatus(
            state: dfu_protocol.DfuState.receiving,
            received: n,
            chunkSize: 68);
      }
      transport.queueDfuStatus(
          state: dfu_protocol.DfuState.ready, received: 1024, chunkSize: 68);

      final samples = <double>[];
      session.addListener(() => samples.add(session.progress));

      await session.start(image);

      final partial = samples.where((p) => p > 0 && p < 1).toList();
      expect(partial, isNotEmpty,
          reason: 'the bar must move while the image is still going out');
    });

    test('a window is re-sent, not the whole image', () async {
      // A drop costs one window of rework. The first version re-sent
      // everything after the acknowledged offset, at the same rate that had
      // just overrun the controller.
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 5),
        windowBytes: 256,
        packetGap: Duration.zero,
      );
      addTearDown(session.dispose);

      final image = Uint8List(1024)..[0] = 0xE9;

      transport.queueOk();
      transport.queueDfuStatus(
          state: dfu_protocol.DfuState.receiving, received: 0, chunkSize: 68);
      // The first window lands, the second is lost, then everything lands.
      for (final n in [256, 256, 512, 768, 1024]) {
        transport.queueDfuStatus(
            state: dfu_protocol.DfuState.receiving,
            received: n,
            chunkSize: 68);
      }
      transport.queueDfuStatus(
          state: dfu_protocol.DfuState.ready, received: 1024, chunkSize: 68);

      await session.start(image);

      final sent = transport.writeDataLog
          .fold<int>(0, (n, p) => n + p.length - 4);
      expect(sent, lessThan(image.length * 2),
          reason: 'one lost window must not cost a second full image');
      expect(session.bytesAcknowledged, 1024);
    });

    test('packets carry ascending offsets within a window', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(
        transport,
        pollInterval: const Duration(milliseconds: 5),
        windowBytes: 256,
        packetGap: Duration.zero,
      );
      addTearDown(session.dispose);

      transport.queueOk();
      transport.queueDfuStatus(
          state: dfu_protocol.DfuState.receiving, received: 0, chunkSize: 68);
      transport.queueDfuStatus(
          state: dfu_protocol.DfuState.ready, received: 256, chunkSize: 68);

      await session.start(Uint8List(256)..[0] = 0xE9);

      final offsets = transport.writeDataLog
          .map((p) => p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24))
          .toList();
      expect(offsets.first, 0);
      for (var i = 1; i < offsets.length; i++) {
        expect(offsets[i], greaterThan(offsets[i - 1]));
      }
    });
  });

  group('recovering from a stuck controller', () {
    test('every attempt clears whatever the last one left open', () async {
      // THE BUG THIS COVERS.
      //
      // A failed transfer leaves the controller's Update session live, and
      // the next DFU_BEGIN is refused with ErrState. The state is on the
      // controller, so closing and reopening the app changed nothing -- the
      // pilot was stuck with no way to reset it and no reason to know it
      // existed. ABORT is safe when nothing is in progress, so it costs one
      // request and makes "try again" mean what it looks like.
      final transport = FakeDfuTransport();
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      transport.queueOk();  // DFU_BEGIN

      await session.start(Uint8List(256)..[0] = 0xE9);

      expect(transport.requestLog.first.op, dfu_protocol.opDfuAbort,
          reason: 'the abort goes first, before anything can be refused');
      expect(transport.requestLog[1].op, dfu_protocol.opDfuBegin);
    });

    test('a rejected image aborts nothing, because nothing was started',
        () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      await session.start(Uint8List(256));  // no 0xE9

      expect(session.outcome, isA<DfuRejectedImage>());
      expect(transport.requestLog, isEmpty);
    });
  });

  group('the state the controller reports', () {
    /// Queues a DFU_BEGIN answer and the first status poll, so each test
    /// below only has to say what the *second* poll reports.
    FakeDfuTransport startedTransport() {
      final transport = FakeDfuTransport();
      transport.queueOk();
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 0,
        chunkSize: 244,
      );
      return transport;
    }

    test('an error mid-transfer is reported as the controller failing, not '
        'as silence', () async {
      final transport = startedTransport();
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      // The controller's own flash write failed. `received` still holds the
      // last accepted offset, so nothing about the number says so -- the
      // state byte beside it is the only signal, and it used to be read
      // only after the whole image had been sent.
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.error,
        received: 512,
      );

      await session.start(Uint8List(4096)..[0] = 0xE9);

      expect(session.outcome, isA<DfuControllerError>());
      expect(session.state, DfuTransferState.failed);
    });

    test('a controller that restarted is not a controller that stalled',
        () async {
      final transport = startedTransport();
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      // A restart clears the session and resets `received` to zero, which as
      // a bare number is exactly what a transfer that never moved looks like.
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.idle,
        received: 0,
      );

      await session.start(Uint8List(4096)..[0] = 0xE9);

      expect(session.outcome, isA<DfuControllerRestarted>());
    });

    test('a complete image is ready without the controller ever saying ready',
        () async {
      final transport = startedTransport();
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      // Both polls report `receiving`, because that is all the firmware ever
      // reports before a commit. A session waiting for `ready` here would
      // poll until the pilot gave up -- and the button that produces `ready`
      // is the one the wait was blocking.
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 1024,
      );
      transport.queueDfuStatus(
        state: dfu_protocol.DfuState.receiving,
        received: 1024,
      );

      await session.start(Uint8List(1024)..[0] = 0xE9);

      expect(session.state, DfuTransferState.ready);
      expect(session.outcome, isA<DfuReady>());
    });
  });

  group('committing', () {
    /// Drives a session to `ready` so commit() can be exercised.
    Future<DfuSession> readySession(FakeDfuTransport transport) async {
      transport.queueOk();
      for (var i = 0; i < 3; i++) {
        transport.queueDfuStatus(
          state: dfu_protocol.DfuState.receiving,
          received: i == 0 ? 0 : 1024,
        );
      }
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      await session.start(Uint8List(1024)..[0] = 0xE9);
      expect(session.state, DfuTransferState.ready);
      return session;
    }

    test('a refused commit is a failure, not a commit', () async {
      final transport = FakeDfuTransport();
      final session = await readySession(transport);
      addTearDown(session.dispose);

      // ErrState from DFU_COMMIT is commitAllowed() refusing: the image is
      // short, or its CRC does not match what DFU_BEGIN promised.
      transport.queueRefused(ControlStatus.errState);
      await session.commit();

      // The answer used to be discarded outright, so this reported success
      // and sent the pilot to an aircraft still running the old firmware.
      //
      // DfuCommitRefused, not DfuFailed(rejected): the image arrived whole
      // and passed the controller's own CRC, so naming it a bad image sends
      // the pilot to download the firmware again for a fault in the
      // controller's flash write.
      expect(session.outcome, isA<DfuCommitRefused>());
      expect(session.state, DfuTransferState.failed);
    });

    test('a commit the controller accepts is reported as committed', () async {
      final transport = FakeDfuTransport();
      final session = await readySession(transport);
      addTearDown(session.dispose);

      transport.queueOk();
      await session.commit();

      expect(session.outcome, isA<DfuCommitted>());
      expect(session.state, DfuTransferState.committed);
    });
  });

  group('the diagnostic trail', () {
    test('names the step that failed and what it answered', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      transport.queueRefused(ControlStatus.errAuth);
      await session.start(Uint8List(256)..[0] = 0xE9);

      // The whole reason this exists: "falhou" names an outcome, and the
      // outcome was never the part in doubt. The failing step was.
      expect(session.trail.join('\n'), contains('DFU_BEGIN'));
      expect(session.trail.join('\n'), contains('errAuth'));
    });

    test('a new attempt does not inherit the last one\'s trail', () async {
      final transport = FakeDfuTransport();
      final session = DfuSession(transport,
          pollInterval: const Duration(milliseconds: 5));
      addTearDown(session.dispose);

      transport.queueRefused(ControlStatus.errAuth);
      await session.start(Uint8List(256)..[0] = 0xE9);
      final first = session.trail.length;

      transport.queueRefused(ControlStatus.errBusy);
      await session.start(Uint8List(256)..[0] = 0xE9);

      expect(session.trail.length, first,
          reason: 'a retry that showed both attempts would read as one');
      expect(session.trail.join('\n'), isNot(contains('errAuth')));
    });
  });
}
