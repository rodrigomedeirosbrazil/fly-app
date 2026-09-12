import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/bms_scan.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/ui/settings/power_settings_screen.dart';

/// 18 Ah, 3.15–4.15 V per cell over 14 cells, ratio 11.00.
const power = PowerConfig(
  capacityMah: 18000,
  minVoltageMv: 44100,
  maxVoltageMv: 58100,
  powerControlEnabled: true,
  voltageDividerRatio: 11.0,
);

Widget wrap(Widget child) => MaterialApp(home: child);

class RecordingEditor implements ConfigEditor {
  @override
  void Function(SaveOk)? get onGroupRead => null;

  final saves = <PowerConfig>[];
  SaveOutcome outcome = const SaveOk();

  /// Answers taken in order before falling back to [outcome], so a test can
  /// drive the PIN round trip: refuse once, then accept.
  final queued = <SaveOutcome>[];

  @override
  bool get authenticated => true;

  @override
  Future<SaveOutcome> savePower(PowerConfig c, {String? pin}) async {
    saves.add(c);
    return queued.isEmpty ? outcome : queued.removeAt(0);
  }

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

  setUp(() => editor = RecordingEditor());

  PowerSettingsScreen screen({
    bool armed = false,
    PowerConfig? config = power,
    double? sensorVolts = 50.4,
  }) =>
      PowerSettingsScreen(
        editor: editor,
        config: config,
        armed: armed,
        sensorVolts: sensorVolts,
      );

  Finder save() => find.byKey(const Key('save-power'));

  Future<void> tapSave(WidgetTester tester) async {
    await tester.ensureVisible(save());
    await tester.pumpAndSettle();
    await tester.tap(save());
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pump();
  }

  group('voltages are per cell, with the pack total beside them', () {
    testWidgets('a stored pack voltage opens as volts per cell',
        (tester) async {
      await tester.pumpWidget(wrap(screen()));
      // 44100 mV / 14 = 3.15 V
      expect(find.text('3.15'), findsOneWidget);
      // 58100 mV / 14 = 4.15 V
      expect(find.text('4.15'), findsOneWidget);
    });

    testWidgets('the total is shown and names the cell count', (tester) async {
      await tester.pumpWidget(wrap(screen()));
      expect(find.textContaining('44.10'), findsOneWidget);
      expect(find.textContaining('58.10'), findsOneWidget);
      expect(find.textContaining('14 células'), findsWidgets);
    });

    testWidgets('the total recomputes as the pilot types', (tester) async {
      await tester.pumpWidget(wrap(screen()));
      await type(tester, 'min-voltage-cell', '3.00');
      expect(find.textContaining('42.00'), findsOneWidget);
    });

    testWidgets('saving converts back to pack millivolts', (tester) async {
      await tester.pumpWidget(wrap(screen()));
      await type(tester, 'min-voltage-cell', '3.00');
      await tapSave(tester);

      expect(editor.saves.single.minVoltageMv, 42000);
      expect(editor.saves.single.maxVoltageMv, 58100);
    });
  });

  group('capacity', () {
    testWidgets('a preset capacity selects its preset', (tester) async {
      await tester.pumpWidget(wrap(screen()));
      expect(find.text('18 Ah'), findsOneWidget);
      expect(find.byKey(const Key('capacity-custom')), findsNothing);
    });

    testWidgets('a capacity that is not a preset opens as custom',
        (tester) async {
      await tester.pumpWidget(wrap(screen(
        config: PowerConfig(
          capacityMah: 22000,
          minVoltageMv: 44100,
          maxVoltageMv: 58100,
          powerControlEnabled: true,
          voltageDividerRatio: 11.0,
        ),
      )));

      // Anything else would have the dropdown lie about the controller.
      expect(find.byKey(const Key('capacity-custom')), findsOneWidget);
      expect(find.text('22'), findsOneWidget);
    });

    testWidgets('a preset saves as milliamp-hours', (tester) async {
      await tester.pumpWidget(wrap(screen()));
      await tapSave(tester);
      expect(editor.saves.single.capacityMah, 18000);
    });
  });

  group('power control', () {
    testWidgets('the pilot can turn it off, and that is what gets saved',
        (tester) async {
      // The firmware gates all derating on this flag, so a screen that shows
      // it without letting it change is a setting the pilot can only reach
      // from the web portal.
      await tester.pumpWidget(wrap(screen()));

      final box = find.byType(CheckboxListTile);
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pumpAndSettle();

      await tapSave(tester);
      expect(editor.saves.single.powerControlEnabled, isFalse);
    });
  });

  testWidgets('the PIN round trip keeps what the pilot changed', (tester) async {
    // The re-save after the PIN dialog rebuilds the config. Rebuilding it from
    // widget.config instead of the fields would silently discard the edit the
    // pilot just made -- and they would see "Gravado" either way.
    editor.queued.add(const SaveNeedsPin());
    await tester.pumpWidget(wrap(screen()));

    final box = find.byType(CheckboxListTile);
    await tester.ensureVisible(box);
    await tester.pumpAndSettle();
    await tester.tap(box);
    await tester.pumpAndSettle();

    await tapSave(tester);

    await tester.enterText(find.byType(TextField).last, '1234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(editor.saves, hasLength(2));
    expect(editor.saves.last.powerControlEnabled, isFalse,
        reason: 'the re-save must carry the fields, not the original config');
  });

  group('rounding', () {
    testWidgets('a per-cell voltage converts without losing a millivolt',
        (tester) async {
      // 3.05 * 14 * 1000 is 42699.99999999999 in binary floating point.
      // Truncating gives 42699 mV, and reopening the screen still shows 3.05
      // -- so the error is invisible from the screen that caused it.
      await tester.pumpWidget(wrap(screen()));
      await type(tester, 'min-voltage-cell', '3.05');
      await tapSave(tester);

      expect(editor.saves.single.minVoltageMv, 42700);
    });
  });

  group('calibration', () {
    testWidgets('shows the live sensor reading', (tester) async {
      await tester.pumpWidget(wrap(screen(sensorVolts: 50.4)));
      expect(find.textContaining('50.40'), findsWidgets);
    });

    testWidgets('is inert without a trustworthy reading', (tester) async {
      // Calibrating against a value the firmware does not trust is worse than
      // not calibrating.
      await tester.pumpWidget(wrap(screen(sensorVolts: null)));
      await type(tester, 'bms-reference', '51.20');
      expect(
        tester.widget<OutlinedButton>(find.byKey(const Key('calibrate')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('computes the new ratio and shows it before applying',
        (tester) async {
      await tester.pumpWidget(wrap(screen(sensorVolts: 50.4)));
      await type(tester, 'bms-reference', '51.20');

      // 11.00 * (51.20 / 50.40) = 11.1746...
      expect(find.textContaining('11.17'), findsOneWidget);
      expect(editor.saves, isEmpty, reason: 'shown, not yet written');
    });

    testWidgets('applying writes the power group with the new ratio',
        (tester) async {
      await tester.pumpWidget(wrap(screen(sensorVolts: 50.4)));
      await type(tester, 'bms-reference', '51.20');

      await tester.ensureVisible(find.byKey(const Key('calibrate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calibrate')));
      await tester.pumpAndSettle();

      expect(editor.saves, hasLength(1));
      expect(editor.saves.single.voltageDividerRatio, closeTo(11.17, 0.01));
    });

    testWidgets('a reference no pack produces is refused', (tester) async {
      await tester.pumpWidget(wrap(screen(sensorVolts: 50.4)));
      await type(tester, 'bms-reference', '5');

      expect(
        tester.widget<OutlinedButton>(find.byKey(const Key('calibrate')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('10 a 65'), findsOneWidget);
    });
  });

  group('the save button', () {
    testWidgets('is live for a valid group', (tester) async {
      await tester.pumpWidget(wrap(screen()));
      await tapSave(tester);
      expect(editor.saves, hasLength(1));
    });

    testWidgets('goes inert when the minimum reaches the maximum',
        (tester) async {
      await tester.pumpWidget(wrap(screen()));
      await type(tester, 'min-voltage-cell', '4.15');

      expect(tester.widget<FilledButton>(save()).onPressed, isNull);
      expect(find.textContaining('menor que a máxima'), findsOneWidget);
    });

    testWidgets('armed makes it inert and says so', (tester) async {
      await tester.pumpWidget(wrap(screen(armed: true)));
      expect(tester.widget<FilledButton>(save()).onPressed, isNull);
      expect(find.textContaining('armada'), findsWidgets);
    });
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
