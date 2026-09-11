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

/// Stands in for the controller's scanner. `next` is what the poll answers,
/// so a test can hand the screen a real result list -- which is the only way
/// to exercise the two rules that live in the results: an unidentified device
/// must not move the type dropdown, and the count line must report the
/// controller's total rather than the length of the truncated list.
class _MockEditor implements ConfigEditor {
  BmsScanState? next;

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
  Future<BmsScanState?> readBmsScan() async => next;
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
  late _MockEditor scanEditor;

  setUp(() {
    editor = RecordingEditor();
    scanEditor = _MockEditor();
    scanController = BmsScanController(scanEditor,
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

  /// Runs one scan to completion so [scanController] holds real results.
  ///
  /// The status is `complete`, so the first poll ends the scan and leaves no
  /// timer running for pumpAndSettle to wait on.
  Future<void> completeScan(
    WidgetTester tester, {
    required int total,
    required List<List<int>> results,
  }) async {
    scanEditor.next = BmsScanState(
      status: BmsScanStatus.complete,
      total: total,
      results: [
        for (final r in results)
          BmsScanResult(
              mac: r.sublist(0, 6), rssi: r[6], detectedType: r[7]),
      ],
    );
    await tester.runAsync(() async {
      await scanController.start(pin: '1234');
      while (scanController.status == BmsScanStatus.scanning) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
  }

  testWidgets('tapping a result fills the address and the detected type',
      (tester) async {
    await completeScan(tester, total: 1, results: [
      [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, -62, 3],
    ]);
    await tester.pumpWidget(wrap(screen(config: const BmsConfig(
        bmsType: 0, bmsMac: kUnsetMac))));

    final tile = find.byKey(const Key('scan-result-0'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    await tapSave(tester);
    expect(editor.saves.single.bmsMac, [0x11, 0x22, 0x33, 0x44, 0x55, 0x66]);
    expect(editor.saves.single.bmsType, 3);
  });

  testWidgets('a result with no detected type leaves the dropdown alone',
      (tester) async {
    // The app never sends BMS_DETECT -- it can block the firmware past its
    // 10 s watchdog and reboot the controller -- so an unidentified device is
    // one the pilot names. Overwriting the type with 0 here would silently
    // turn the BMS off.
    await completeScan(tester, total: 1, results: [
      [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, -88, 0],
    ]);
    await tester.pumpWidget(wrap(screen()));  // stored type is 1 (JBD)

    final tile = find.byKey(const Key('scan-result-0'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    await tapSave(tester);
    expect(editor.saves.single.bmsMac, [0x11, 0x22, 0x33, 0x44, 0x55, 0x66]);
    expect(editor.saves.single.bmsType, 1, reason: 'the stored type must survive');
  });

  testWidgets('the count line reports the controller total, not the list '
      'length', (tester) async {
    // The firmware truncates the reply to one BLE frame while `count` still
    // carries the true total. Believing the list would under-report what the
    // scan saw.
    await completeScan(tester, total: 30, results: [
      [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, -50, 1],
    ]);
    await tester.pumpWidget(wrap(screen()));

    final line = find.byKey(const Key('scan-truncated'));
    await tester.ensureVisible(line);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(line).data, contains('30'));
  });

  testWidgets('a list that matches the count shows no truncation line',
      (tester) async {
    await completeScan(tester, total: 1, results: [
      [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, -50, 1],
    ]);
    await tester.pumpWidget(wrap(screen()));

    expect(find.byKey(const Key('scan-truncated')), findsNothing);
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
