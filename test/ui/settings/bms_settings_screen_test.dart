import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/bms_scan.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/protocol/mac_address.dart';
import 'package:fly_app/state/bms_scan_controller.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/ui/settings/bms_settings_screen.dart';

const bmsConfig = BmsConfig(
  bmsType: 1,
  bmsMac: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
);

Widget wrap(Widget child) => MaterialApp(home: child);

class RecordingEditor implements ConfigEditor {
  final saves = <BmsConfig>[];
  SaveOutcome outcome = const SaveOk();

  final queued = <SaveOutcome>[];

  @override
  bool get authenticated => true;

  @override
  Future<SaveOutcome> savePower(PowerConfig c, {String? pin}) async =>
      const SaveOk();

  @override
  Future<SaveOutcome> saveThermal(ThermalConfig c, {String? pin}) async =>
      const SaveOk();

  @override
  Future<SaveOutcome> saveBms(BmsConfig config, {String? pin}) async {
    saves.add(config);
    return queued.isEmpty ? outcome : queued.removeAt(0);
  }

  @override
  Future<SaveOutcome> saveSystem(SystemConfig config, {String? pin}) async =>
      const SaveOk();

  @override
  Future<SaveOutcome> startBmsScan({String? pin}) async => const SaveOk();

  @override
  Future<BmsScanState?> readBmsScan() async => null;

  @override
  Future<SystemConfig?> readSystemConfig() async => null;

  @override
  Future<SaveOutcome> pairRemote({String? pin}) async => const SaveOk();

  @override
  Future<SaveOutcome> forgetRemote({String? pin}) async => const SaveOk();

  @override
  Future<SaveOutcome> previewBuzzer(int volume, {String? pin}) async =>
      const SaveOk();
}

class _MockEditor implements ConfigEditor {
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
  Future<SaveOutcome> saveSystem(SystemConfig config, {String? pin}) async =>
      const SaveOk();
  @override
  Future<SaveOutcome> startBmsScan({String? pin}) async => const SaveOk();
  @override
  Future<BmsScanState?> readBmsScan() async => null;
  @override
  Future<SystemConfig?> readSystemConfig() async => null;
  @override
  Future<SaveOutcome> pairRemote({String? pin}) async => const SaveOk();
  @override
  Future<SaveOutcome> forgetRemote({String? pin}) async => const SaveOk();
  @override
  Future<SaveOutcome> previewBuzzer(int volume, {String? pin}) async =>
      const SaveOk();
}

void main() {
  late RecordingEditor editor;
  late BmsScanController scanController;

  setUp(() {
    editor = RecordingEditor();
    scanController = BmsScanController(_MockEditor(),
        pollInterval: const Duration(milliseconds: 10));
  });

  tearDown(() => scanController.dispose());

  BmsSettingsScreen screen({
    bool armed = false,
    BmsConfig? config = bmsConfig,
    bool? bmsConnected,
    bool? bmsConfigured,
  }) =>
      BmsSettingsScreen(
        editor: editor,
        scanController: scanController,
        config: config,
        armed: armed,
        bmsConnected: bmsConnected,
        bmsConfigured: bmsConfigured,
      );

  Finder save() => find.byKey(const Key('save-bms'));
  Finder scanButton() => find.byKey(const Key('scan-bms'));

  Future<void> tapSave(WidgetTester tester) async {
    await tester.ensureVisible(save());
    await tester.pumpAndSettle();
    await tester.tap(save());
    await tester.pumpAndSettle();
  }

  testWidgets('shows the stored type and address', (tester) async {
    await tester.pumpWidget(wrap(screen()));
    expect(find.text('JBD'), findsOneWidget);
    expect(find.text('AA:BB:CC:DD:EE:FF'), findsOneWidget);
  });

  testWidgets('an unset address reads as não configurado', (tester) async {
    const unsetConfig = BmsConfig(bmsType: 0, bmsMac: kUnsetMac);
    await tester.pumpWidget(wrap(screen(config: unsetConfig)));
    expect(find.text('não configurado'), findsOneWidget);
  });

  testWidgets('a result with no address but valid MAC is accepted',
      (tester) async {
    const unsetConfig = BmsConfig(bmsType: 0, bmsMac: kUnsetMac);
    await tester.pumpWidget(wrap(screen(config: unsetConfig)));

    // Open manual entry and enter a valid MAC
    await tester.tap(find.byKey(const Key('manual-mac-toggle')));
    await tester.pump();

    await tester.enterText(
        find.byKey(const Key('manual-mac')), 'AA:BB:CC:DD:EE:FF');
    await tester.pump();

    // Save should now be enabled (type is 0, but MAC is set)
    expect(tester.widget<ElevatedButton>(save()).onPressed, isNotNull);
  });

  testWidgets('a type with no address makes save inert, with the reason',
      (tester) async {
    const configWithType = BmsConfig(bmsType: 2, bmsMac: kUnsetMac);
    await tester.pumpWidget(wrap(screen(config: configWithType)));

    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
    expect(find.textContaining('endereço do BMS'), findsOneWidget);
  });

  testWidgets('armed makes save and the scan inert', (tester) async {
    await tester.pumpWidget(wrap(screen(armed: true)));

    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
    expect(tester.widget<ElevatedButton>(scanButton()).onPressed, isNull);
    expect(find.textContaining('armada'), findsWidgets);
  });

  testWidgets('manual entry refuses a half-typed MAC', (tester) async {
    await tester.pumpWidget(wrap(screen()));

    // Open manual entry
    await tester.tap(find.byKey(const Key('manual-mac-toggle')));
    await tester.pump();

    // Enter invalid MAC
    await tester.enterText(find.byKey(const Key('manual-mac')), 'AA:BB:CC');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
  });

  testWidgets('the PIN round trip carries what is on screen', (tester) async {
    editor.queued.add(const SaveNeedsPin());
    await tester.pumpWidget(wrap(screen()));

    // Change the type through the dropdown
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daly (D2 BLE)').last);
    await tester.pumpAndSettle();

    await tapSave(tester);

    await tester.enterText(find.byType(TextField).last, '1234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(editor.saves, hasLength(2));
    expect(editor.saves.last.bmsType, 2,
        reason: 'the re-save must carry the fields, not the original config');
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

        await tester.pumpWidget(wrap(screen()));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });
}
