import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/net/release_feed.dart';
import 'package:fly_app/protocol/control_info.dart';
import 'package:fly_app/protocol/dfu_protocol.dart';
import 'package:fly_app/state/control_session.dart';
import 'package:fly_app/state/dfu_session.dart';
import 'package:fly_app/state/firmware_update_checker.dart';
import 'package:fly_app/state/buzzer_mirror.dart';
import 'package:fly_app/state/telemetry_repository.dart';
import 'package:fly_app/ui/settings/firmware_screen.dart';

import '../../state/fake_firmware_feed.dart';
import '../../state/fake_link.dart';
import '../../state/fake_tone_player.dart';

/// A transport that answers nothing. Every case here is about what the screen
/// offers before a transfer starts, so the session never needs to progress.
class SilentTransport implements DfuTransport {
  final writes = <List<int>>[];

  @override
  int get maxWriteBytes => 512;

  @override
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) async =>
      const ControlTimeout();

  @override
  Future<void> writeData(List<int> bytes) async => writes.add(bytes);

  @override
  Future<bool> authenticate(String pin) async => true;
}

/// Answers everything instantly except DFU_BEGIN, which never answers. The
/// session has left `idle` by then, so a transfer stays in flight for as long
/// as the test needs.
class HoldingTransport extends SilentTransport {
  final begin = Completer<ControlResult>();

  @override
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) =>
      op == opDfuBegin
          ? begin.future
          : super.request(op: op, payload: payload);
}

Widget wrap(Widget child) => MaterialApp(home: child);

Uint8List image({int first = 0xE9, int length = 2048}) =>
    Uint8List(length)..[0] = first;

void main() {
  late SilentTransport transport;
  late DfuSession session;
  late TelemetryRepository repo;
  late FakeLink link;
  late FakeFirmwareFeed feed;
  late FirmwareUpdateChecker updates;

  setUp(() {
    transport = SilentTransport();
    session = DfuSession(transport,
        pollInterval: const Duration(milliseconds: 10), maxRestarts: 1);
    link = FakeLink();
    feed = FakeFirmwareFeed();
    updates = FirmwareUpdateChecker(
      feed: feed,
      installedVersion: '2026-09-12.1',
      controllerType: ControllerType.xag,
    );
    // A mirror with a silent player: the default builds a real audio player,
    // which throws off the platform channel in a widget test and reds the
    // whole file from an async gap.
    repo = TelemetryRepository(
      link: link,
      clock: DateTime.now,
      mirror: BuzzerMirror(FakeTonePlayer()),
    );
  });

  tearDown(() {
    updates.dispose();
    session.dispose();
    repo.dispose();
  });

  FirmwareSettingsScreen screen({
    bool armed = false,
    bool canUpdate = true,
    Future<Uint8List?> Function()? pick,
  }) =>
      FirmwareSettingsScreen(
        repo: repo,
        session: session,
        updates: updates,
        armed: armed,
        canUpdateFirmware: canUpdate,
        pickFile: pick ?? () async => image(),
      );

  Finder send() => find.byKey(const Key('send-firmware'));
  Finder commit() => find.byKey(const Key('commit-firmware'));

  Future<void> pick(WidgetTester tester) async {
    final button = find.byKey(const Key('pick-firmware'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('the warning is on the page before any send is possible',
      (tester) async {
    // THE RULE THIS SCREEN EXISTS TO ENFORCE.
    //
    // Nothing in an ESP32 image says which controller it is for: XAG and
    // Tmotor builds both pass the magic byte, the size and the CRC. The
    // pilot has to read that before committing, not acknowledge it in a
    // dialog afterwards, because the failure it describes is a controller
    // that will not boot.
    await tester.pumpWidget(wrap(screen()));

    expect(find.textContaining('não tem como saber'), findsOneWidget);
    expect(find.textContaining('cabo USB'), findsOneWidget);
  });

  testWidgets('commit is inert until the controller says it is ready',
      (tester) async {
    await tester.pumpWidget(wrap(screen()));
    await pick(tester);

    await tester.ensureVisible(commit());
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(commit()).onPressed, isNull,
        reason: 'nothing has been transferred, let alone verified');
  });

  testWidgets('a file that is not an ESP32 image is refused with its reason',
      (tester) async {
    // 0xE9 is the ESP32 image magic. Saying so on selection beats spending a
    // minute of transfer to discover it.
    await tester.pumpWidget(
        wrap(screen(pick: () async => image(first: 0x7F))));
    await pick(tester);

    await tester.ensureVisible(send());
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(send()).onPressed, isNull);
    expect(find.textContaining('firmware ESP32'), findsWidgets);
  });

  testWidgets('armed makes every action inert, with the reason',
      (tester) async {
    await tester.pumpWidget(wrap(screen(armed: true)));

    await tester.ensureVisible(send());
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(send()).onPressed, isNull);
    expect(tester.widget<FilledButton>(commit()).onPressed, isNull);
    expect(find.textContaining('armada'), findsWidgets);
  });

  testWidgets('a controller with no DFU says so instead of looking broken',
      (tester) async {
    // Today this is EVERY controller: the firmware counterpart does not
    // exist yet. The screen has to be honest in that state, not inert and
    // silent.
    await tester.pumpWidget(wrap(screen(canUpdate: false)));

    await tester.ensureVisible(send());
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(send()).onPressed, isNull);
    expect(find.textContaining('não aceita atualização'), findsWidgets);
  });

  testWidgets('a pick that throws is reported, not swallowed', (tester) async {
    await tester.pumpWidget(wrap(screen(
      pick: () async => throw StateError('sem permissão'),
    )));
    await pick(tester);

    expect(find.byKey(const Key('pick-error')), findsOneWidget);
    expect(find.textContaining('sem permissão'), findsOneWidget);
  });

  group('layout', () {
    for (final size in const [
      Size(393, 852),
      Size(320, 480),
      Size(852, 393),
      Size(1280, 800),
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(wrap(screen()));
        await tester.pumpAndSettle();
      });
    }
  });

  Finder download() => find.byKey(const Key('download-firmware'));
  Finder retry() => find.byKey(const Key('retry-firmware-check'));

  Future<void> answerRelease(WidgetTester tester) async {
    feed.releaseCalls.single.complete(firmwareRelease());
    await tester.pumpAndSettle();
  }

  testWidgets('opening the screen checks GitHub once', (tester) async {
    await tester.pumpWidget(wrap(screen()));

    expect(feed.releaseCalls, hasLength(1));
    expect(find.text('Verificando no GitHub…'), findsOneWidget);
  });

  testWidgets('a newer release offers its download with the size', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(screen()));
    await answerRelease(tester);

    expect(find.text('Disponível 2026-10-02.2'), findsOneWidget);
    expect(find.text('Baixar 2026-10-02.2 (0,0 MB)'), findsOneWidget);
  });

  testWidgets('up to date says so and offers nothing', (tester) async {
    updates.dispose();
    updates = FirmwareUpdateChecker(
      feed: feed,
      installedVersion: '2026-10-02.2',
      controllerType: ControllerType.xag,
    );
    await tester.pumpWidget(wrap(screen()));
    await answerRelease(tester);

    expect(find.text('Atualizado'), findsOneWidget);
    expect(download(), findsNothing);
  });

  testWidgets('a dev build is offered the latest, and told why', (
    tester,
  ) async {
    updates.dispose();
    updates = FirmwareUpdateChecker(
      feed: feed,
      installedVersion: 'dev',
      controllerType: ControllerType.xag,
    );
    await tester.pumpWidget(wrap(screen()));
    await answerRelease(tester);

    expect(find.textContaining('não é de um release'), findsOneWidget);
    expect(download(), findsOneWidget);
  });

  testWidgets('an unknown type gets no download, with the reason', (
    tester,
  ) async {
    updates.dispose();
    updates = FirmwareUpdateChecker(
      feed: feed,
      installedVersion: '2026-09-12.1',
      controllerType: ControllerType.unknown,
    );
    await tester.pumpWidget(wrap(screen()));
    await answerRelease(tester);

    expect(
      find.textContaining('Não há imagem para este controlador'),
      findsOneWidget,
    );
    expect(download(), findsNothing);
  });

  testWidgets('a failed check offers to try again', (tester) async {
    await tester.pumpWidget(wrap(screen()));
    feed.releaseCalls.single.complete(null);
    await tester.pumpAndSettle();

    expect(find.text('Não foi possível verificar'), findsOneWidget);
    await tester.ensureVisible(retry());
    await tester.tap(retry());
    await tester.pump();
    expect(feed.releaseCalls, hasLength(2));
  });

  testWidgets('without a DFU channel the release is shown but not offered', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(screen(canUpdate: false)));
    await answerRelease(tester);

    expect(find.text('Disponível 2026-10-02.2'), findsOneWidget);
    expect(download(), findsNothing);
  });

  testWidgets('downloading is allowed while armed', (tester) async {
    await tester.pumpWidget(wrap(screen(armed: true)));
    await answerRelease(tester);

    await tester.ensureVisible(download());
    expect(tester.widget<FilledButton>(download()).onPressed, isNotNull);
  });

  Future<void> downloadIt(WidgetTester tester) async {
    await answerRelease(tester);
    await tester.ensureVisible(download());
    await tester.tap(download());
    await tester.pump();
  }

  testWidgets('progress shows, and send waits for the download', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(screen()));
    await downloadIt(tester);

    feed.downloadCalls.single.onProgress!(2);
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);

    await tester.ensureVisible(send());
    expect(tester.widget<FilledButton>(send()).onPressed, isNull);
  });

  testWidgets('the downloaded image goes to the same send a picked file does', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(screen()));
    await downloadIt(tester);
    feed.downloadCalls.single.result.complete(Downloaded(firmwareBytes()));
    await tester.pumpAndSettle();

    expect(find.textContaining('firmware-xag-2026-10-02.2.bin'), findsWidgets);
    expect(find.textContaining('baixado do GitHub'), findsOneWidget);

    await tester.ensureVisible(send());
    await tester.pumpAndSettle();
    await tester.tap(send());
    await tester.pump();

    // The silent transport answers every request with a timeout, so start
    // ends in `failed` -- but its trail proves the downloaded 4 bytes reached
    // it and went as far as DFU_BEGIN, which `idle` alone would not.
    expect(session.trail.first, contains('imagem 4 B'));
    expect(session.trail.any((l) => l.contains('DFU_BEGIN')), isTrue);
  });

  testWidgets('the warning names the source only for a downloaded image', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(screen()));
    expect(find.textContaining('não tem como saber'), findsOneWidget);

    await downloadIt(tester);
    feed.downloadCalls.single.result.complete(Downloaded(firmwareBytes()));
    await tester.pumpAndSettle();

    expect(find.textContaining('não tem como saber'), findsNothing);
    expect(
      find.textContaining('escolhida pelo tipo que o controlador informou'),
      findsOneWidget,
    );
    expect(find.textContaining('cabo USB'), findsOneWidget);

    // A manual pick afterwards replaces it, and the generic warning returns.
    await pick(tester);
    expect(find.textContaining('baixado do GitHub'), findsNothing);
    expect(find.textContaining('não tem como saber'), findsOneWidget);
  });

  testWidgets('a failed download says so and offers the button again', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(screen()));
    await downloadIt(tester);
    feed.downloadCalls.single.result.complete(const DownloadIncomplete());
    await tester.pumpAndSettle();

    expect(find.text('Download incompleto'), findsOneWidget);
    expect(download(), findsOneWidget);
    expect(find.text('Tentar de novo'), findsOneWidget);
  });

  testWidgets('a refused download says so and offers the button again',
      (tester) async {
    await tester.pumpWidget(wrap(screen()));
    await downloadIt(tester);
    feed.downloadCalls.single.result.complete(const DownloadFailed());
    await tester.pumpAndSettle();

    expect(find.text('Falha no download'), findsOneWidget);
    expect(download(), findsOneWidget);
    expect(find.text('Tentar de novo'), findsOneWidget);
  });

  testWidgets('a finished download says Baixado', (tester) async {
    await tester.pumpWidget(wrap(screen()));
    await downloadIt(tester);
    feed.downloadCalls.single.result.complete(Downloaded(firmwareBytes()));
    await tester.pumpAndSettle();

    expect(find.text('Baixado'), findsOneWidget);
  });

  testWidgets('during a transfer the download stays, disabled', (tester) async {
    // Fixed presence, varying state: hiding the button would shift the send
    // and progress area while the pilot watches it.
    session.dispose();
    final holding = HoldingTransport();
    session = DfuSession(holding,
        pollInterval: const Duration(milliseconds: 10), maxRestarts: 1);
    await tester.pumpWidget(wrap(screen()));
    await answerRelease(tester);
    await pick(tester);

    await tester.ensureVisible(send());
    await tester.tap(send());
    await tester.pump();
    await tester.pump();
    expect(session.isTransferring, isTrue,
        reason: 'DFU_BEGIN is unanswered, so the transfer is in flight');

    await tester.ensureVisible(download());
    expect(download(), findsOneWidget);
    expect(tester.widget<FilledButton>(download()).onPressed, isNull);
  });

  testWidgets('a manual pick can be undone by using the downloaded image',
      (tester) async {
    await tester.pumpWidget(wrap(screen()));
    await downloadIt(tester);
    feed.downloadCalls.single.result.complete(Downloaded(firmwareBytes()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('use-downloaded-firmware')), findsNothing);

    await pick(tester);
    expect(find.textContaining('baixado do GitHub'), findsNothing);

    final useIt = find.byKey(const Key('use-downloaded-firmware'));
    await tester.ensureVisible(useIt);
    await tester.tap(useIt);
    await tester.pumpAndSettle();

    expect(feed.downloadCalls, hasLength(1), reason: 'no second download');
    expect(find.textContaining('baixado do GitHub'), findsOneWidget);
    expect(find.textContaining('escolhida pelo tipo que o controlador informou'),
        findsOneWidget);
    expect(find.textContaining('não tem como saber'), findsNothing);
    expect(useIt, findsNothing);
  });

  testWidgets('picking a file waits for a download in flight', (tester) async {
    // Otherwise the download would finish and overwrite the pick.
    await tester.pumpWidget(wrap(screen()));
    await downloadIt(tester);

    final button = find.byKey(const Key('pick-firmware'));
    await tester.ensureVisible(button);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
  });
}
