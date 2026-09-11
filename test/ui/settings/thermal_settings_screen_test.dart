import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/ui/settings/thermal_settings_screen.dart';

const thermal = ThermalConfig(
  motorReductionStartC: 80,
  motorMaxC: 100,
  escReductionStartC: 70,
  escMaxC: 95,
  motorTempSource: 0,
);

Widget wrap(Widget child) => MaterialApp(home: child);

class RecordingEditor implements ConfigEditor {
  final saves = <ThermalConfig>[];
  SaveOutcome outcome = const SaveOk();

  /// Answers taken in order before falling back to [outcome], so a test can
  /// drive the PIN round trip: refuse once, then accept.
  final queued = <SaveOutcome>[];

  @override
  bool get authenticated => true;

  @override
  Future<SaveOutcome> savePower(PowerConfig c, {String? pin}) async =>
      const SaveOk();

  @override
  Future<SaveOutcome> saveThermal(ThermalConfig c, {String? pin}) async {
    saves.add(c);
    return queued.isEmpty ? outcome : queued.removeAt(0);
  }
}

void main() {
  late RecordingEditor editor;

  setUp(() => editor = RecordingEditor());

  ThermalSettingsScreen screen({
    bool armed = false,
    bool selectableSource = false,
    ThermalConfig? config = thermal,
  }) =>
      ThermalSettingsScreen(
        editor: editor,
        config: config,
        armed: armed,
        selectableMotorTempSource: selectableSource,
      );

  Finder save() => find.byKey(const Key('save-thermal'));

  Future<void> tapSave(WidgetTester tester) async {
    await tester.ensureVisible(save());
    await tester.pumpAndSettle();
    await tester.tap(save());
    await tester.pumpAndSettle();
  }

  testWidgets('shows the four thresholds in whole degrees', (tester) async {
    await tester.pumpWidget(wrap(screen()));
    expect(find.text('80'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('70'), findsOneWidget);
    expect(find.text('95'), findsOneWidget);
  });

  testWidgets('saves what is on screen', (tester) async {
    await tester.pumpWidget(wrap(screen()));
    await tapSave(tester);

    expect(editor.saves, hasLength(1));
    expect(editor.saves.single.motorReductionStartC, closeTo(80, 1e-9));
    expect(editor.saves.single.escMaxC, closeTo(95, 1e-9));
  });

  testWidgets('an inverted pair makes save inert, with the reason',
      (tester) async {
    await tester.pumpWidget(wrap(screen()));
    await tester.enterText(find.byKey(const Key('motor-start')), '100');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
    expect(find.textContaining('precisa ser menor'), findsOneWidget);
  });

  testWidgets('a value past the firmware range makes save inert',
      (tester) async {
    await tester.pumpWidget(wrap(screen()));
    await tester.enterText(find.byKey(const Key('motor-max')), '200');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
    expect(find.textContaining('0 a 150'), findsOneWidget);
  });

  testWidgets('a field that is not a number goes inert, never to zero',
      (tester) async {
    await tester.pumpWidget(wrap(screen()));
    // enterText bypasses the input formatter the same way a paste or a
    // hardware keyboard does, which is the case the formatter cannot cover.
    await tester.enterText(find.byKey(const Key('motor-start')), 'abc');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
    expect(find.textContaining('números válidos'), findsOneWidget);
  });

  testWidgets('an empty field is unanswered, not zero', (tester) async {
    await tester.pumpWidget(wrap(screen()));
    await tester.enterText(find.byKey(const Key('esc-start')), '');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
  });

  testWidgets('a comma is a decimal separator, not a rejection',
      (tester) async {
    await tester.pumpWidget(wrap(screen()));
    await tester.enterText(find.byKey(const Key('motor-start')), '82,5');
    await tester.pump();
    await tapSave(tester);

    expect(editor.saves.single.motorReductionStartC, closeTo(82.5, 1e-9));
  });

  testWidgets('armed makes save inert and says so', (tester) async {
    await tester.pumpWidget(wrap(screen(armed: true)));
    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
    expect(find.textContaining('armada'), findsWidgets);
  });

  testWidgets('the source control needs the capability bit', (tester) async {
    await tester.pumpWidget(wrap(screen(selectableSource: false)));
    expect(find.text('Origem da temperatura do motor'), findsNothing);

    await tester.pumpWidget(wrap(screen(selectableSource: true)));
    expect(find.text('Origem da temperatura do motor'), findsOneWidget);
  });

  testWidgets('no config means nothing to edit and nothing to overwrite',
      (tester) async {
    await tester.pumpWidget(wrap(screen(config: null)));
    expect(tester.widget<ElevatedButton>(save()).onPressed, isNull);
  });

  testWidgets('the PIN round trip carries what is on screen', (tester) async {
    // This path had no test on either settings screen until one drove
    // SaveNeedsPin, and it threw: the dialog disposed its controller while the
    // TextField holding it was still mounted.
    editor.queued.add(const SaveNeedsPin());
    await tester.pumpWidget(wrap(screen()));

    await tester.enterText(find.byKey(const Key('motor-start')), '75');
    await tester.pump();
    await tapSave(tester);

    await tester.enterText(find.byType(TextField).last, '1234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(editor.saves, hasLength(2));
    expect(editor.saves.last.motorReductionStartC, closeTo(75, 1e-9),
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

        await tester.pumpWidget(wrap(screen(selectableSource: true)));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });
}
