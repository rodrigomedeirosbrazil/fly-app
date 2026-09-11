import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/bms_scan.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/mac_address.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/state/remote_pairing_controller.dart';
import 'package:fly_app/ui/settings/system_settings_screen.dart';

const system = SystemConfig(
  buzzerVolume: 70,
  throttleSource: 1,
  remoteMac: kUnsetMac,
);

const remoteSystem = SystemConfig(
  buzzerVolume: 70,
  throttleSource: 1,
  remoteMac: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
);

Widget wrap(Widget child) => MaterialApp(home: child);

class RecordingEditor implements ConfigEditor {
  final saves = <SystemConfig>[];
  SaveOutcome outcome = const SaveOk();
  final queued = <SaveOutcome>[];

  int previewCount = 0;
  final previewedVolumes = <int>[];

  @override
  bool get authenticated => true;

  @override
  Future<SaveOutcome> savePower(PowerConfig c, {String? pin}) async =>
      const SaveOk();

  @override
  Future<SaveOutcome> saveThermal(ThermalConfig c, {String? pin}) async =>
      const SaveOk();

  @override
  Future<SaveOutcome> saveBms(BmsConfig config, {String? pin}) async =>
      const SaveOk();

  @override
  Future<SaveOutcome> saveSystem(SystemConfig config, {String? pin}) async {
    saves.add(config);
    return queued.isEmpty ? outcome : queued.removeAt(0);
  }

  @override
  Future<SaveOutcome> startBmsScan({String? pin}) async => const SaveOk();

  @override
  Future<BmsScanState?> readBmsScan() async => null;

  @override
  /// What the pairing poll sees. `remoteMac` turning non-zero is the ONLY
  /// readback pairing has -- REMOTE_PAIR answers Ok the instant it raises a
  /// flag -- so a test cannot reach the paired state without this.
  SystemConfig? systemReply;

  @override
  Future<SystemConfig?> readSystemConfig() async => systemReply;

  @override
  Future<SaveOutcome> pairRemote({String? pin}) async => const SaveOk();

  @override
  Future<SaveOutcome> forgetRemote({String? pin}) async => const SaveOk();

  @override
  Future<SaveOutcome> previewBuzzer(int volume, {String? pin}) async {
    previewCount++;
    previewedVolumes.add(volume);
    return const SaveOk();
  }
}

void main() {
  late RecordingEditor editor;
  late RemotePairingController pairingController;

  setUp(() {
    editor = RecordingEditor();
    pairingController = RemotePairingController(
      editor,
      pollInterval: const Duration(milliseconds: 10),
      deadline: const Duration(milliseconds: 100),
    );
  });

  tearDown(() {
    pairingController.dispose();
  });

  SystemSettingsScreen screen({
    bool armed = false,
    bool hasRemote = false,
    SystemConfig? config = system,
  }) =>
      SystemSettingsScreen(
        editor: editor,
        pairingController: pairingController,
        config: config,
        armed: armed,
        hasRemoteLink: hasRemote,
      );

  Finder save() => find.byKey(const Key('save-system'));
  Finder buzzerSlider() => find.byKey(const Key('buzzer-volume'));

  testWidgets('shows the stored volume and source', (tester) async {
    await tester.pumpWidget(wrap(screen()));
    expect(find.text('70'), findsOneWidget);
    expect(find.text('Sem fio (ESP-NOW)'), findsOneWidget);
  });

  testWidgets('releasing the slider previews once, not per pixel',
      (tester) async {
    await tester.pumpWidget(wrap(screen()));

    // Change slider by dragging
    final slider = find.byType(Slider);
    await tester.drag(slider, const Offset(50, 0));
    await tester.pumpAndSettle();

    // Preview should have been called once, on release
    expect(editor.previewCount, 1);
  });

  testWidgets('the remote section is absent without the capability bit',
      (tester) async {
    await tester.pumpWidget(wrap(screen(hasRemote: false)));
    expect(find.byKey(const Key('pair-remote')), findsNothing);
    expect(find.byKey(const Key('forget-remote')), findsNothing);
    expect(find.byKey(const Key('remote-mac')), findsNothing);
  });

  testWidgets('the remote section is present with the capability bit',
      (tester) async {
    await tester.pumpWidget(wrap(screen(hasRemote: true)));
    expect(find.byKey(const Key('pair-remote')), findsOneWidget);
    expect(find.byKey(const Key('forget-remote')), findsOneWidget);
    expect(find.byKey(const Key('remote-mac')), findsOneWidget);
  });

  testWidgets('pairing waits for the remote', (tester) async {
    await tester.pumpWidget(wrap(screen(hasRemote: true)));

    // Tap the pair remote button
    await tester.tap(find.byKey(const Key('pair-remote')));
    await tester.pump();

    // Should show the pairing dialog
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('Ligue o remote agora'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Close the dialog to clean up timers
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
  });

  testWidgets('pairing resolves when the MAC appears', (tester) async {
    await tester.pumpWidget(wrap(screen(hasRemote: true)));

    await tester.tap(find.byKey(const Key('pair-remote')));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    // The remote is switched on: the controller writes its MAC, and the next
    // poll of the System group is what tells the app.
    editor.systemReply = const SystemConfig(
      buzzerVolume: 70,
      throttleSource: 1,
      remoteMac: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
    );

    // Periodic timers keep pumpAndSettle from ever settling.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 15));
    }

    expect(find.text('Remote pareado'), findsOneWidget);
    expect(pairingController.state, PairingState.paired);
    expect(pairingController.stillListening, isFalse);
  });

  testWidgets('giving up says the controller is still listening',
      (tester) async {
    // The firmware has no pairing timeout and no cancel opcode, so the
    // deadline is this app's alone. Saying "cancelled" would be a lie the
    // pilot acts on: the next remote powered on nearby still gets paired.
    await tester.pumpWidget(wrap(screen(hasRemote: true)));

    await tester.tap(find.byKey(const Key('pair-remote')));
    await tester.pump();

    // No remote answers. Run past the 100 ms deadline this test configured.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 15));
    }

    expect(pairingController.state, PairingState.gaveUp);
    expect(pairingController.stillListening, isTrue);
    expect(find.textContaining('continua aguardando'), findsOneWidget);
  });

  testWidgets('cancelling says the same thing, because it does the same thing',
      (tester) async {
    await tester.pumpWidget(wrap(screen(hasRemote: true)));

    await tester.tap(find.byKey(const Key('pair-remote')));
    await tester.pump();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('continua aguardando'), findsOneWidget);
    expect(pairingController.stillListening, isTrue);
  });

  testWidgets('forgetting warns that a running remote may survive it',
      (tester) async {
    await tester.pumpWidget(wrap(screen(hasRemote: true)));

    // Tap forget button - should show confirmation dialog first
    await tester.ensureVisible(find.byKey(const Key('forget-remote')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-remote')));
    await tester.pumpAndSettle();

    // Should show the warning about running remotes
    expect(
      find.textContaining('pode continuar funcionando'),
      findsOneWidget,
    );
  });

  testWidgets('armed makes every control inert', (tester) async {
    await tester.pumpWidget(wrap(screen(armed: true, hasRemote: true)));

    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
    expect(tester.widget<Slider>(buzzerSlider()).onChangeEnd, isNull);

    final throttleDropdown = find.byKey(const Key('throttle-source'));
    expect(
      tester.widget<DropdownButton<int>>(throttleDropdown).onChanged,
      isNull,
    );

    expect(
      tester.widget<ElevatedButton>(
        find.byKey(const Key('pair-remote')),
      ).onPressed,
      isNull,
    );
    expect(
      tester.widget<ElevatedButton>(
        find.byKey(const Key('forget-remote')),
      ).onPressed,
      isNull,
    );
  });

  testWidgets('no config means nothing to edit and nothing to overwrite',
      (tester) async {
    await tester.pumpWidget(wrap(screen(config: null)));
    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
  });

  testWidgets('the PIN round trip carries what is on screen', (tester) async {
    editor.queued.add(const SaveNeedsPin());
    await tester.pumpWidget(wrap(screen()));

    // Change volume
    await tester.drag(buzzerSlider(), const Offset(20, 0));
    await tester.pumpAndSettle();

    // Save
    await tester.ensureVisible(save());
    await tester.pumpAndSettle();
    await tester.tap(save());
    await tester.pumpAndSettle();

    // Enter PIN
    await tester.enterText(find.byType(TextField).last, '1234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // Second save should use the screen values, not the original config
    expect(editor.saves, hasLength(2));
    expect(
      editor.saves.last.buzzerVolume,
      isNot(system.buzzerVolume),
      reason: 'the re-save must carry the fields, not the original config',
    );
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
        addTearDown(tester.view.reset);

        await tester.pumpWidget(wrap(screen(hasRemote: true)));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });
}
