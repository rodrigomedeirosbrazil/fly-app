import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/state/control_session.dart';
import 'package:fly_app/state/dfu_session.dart';
import 'package:fly_app/state/buzzer_mirror.dart';
import 'package:fly_app/state/telemetry_repository.dart';
import 'package:fly_app/ui/settings/firmware_screen.dart';

import '../../state/fake_link.dart';
import '../../state/fake_tone_player.dart';

/// A transport that answers nothing. Every case here is about what the screen
/// offers before a transfer starts, so the session never needs to progress.
class SilentTransport implements DfuTransport {
  final writes = <List<int>>[];

  @override
  Future<ControlResult> request({
    required int op,
    List<int> payload = const [],
  }) async =>
      const ControlTimeout();

  @override
  Future<void> writeData(List<int> bytes) async => writes.add(bytes);
}

Widget wrap(Widget child) => MaterialApp(home: child);

Uint8List image({int first = 0xE9, int length = 2048}) =>
    Uint8List(length)..[0] = first;

void main() {
  late SilentTransport transport;
  late DfuSession session;
  late TelemetryRepository repo;
  late FakeLink link;

  setUp(() {
    transport = SilentTransport();
    session = DfuSession(transport,
        pollInterval: const Duration(milliseconds: 10), maxRestarts: 1);
    link = FakeLink();
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
}
