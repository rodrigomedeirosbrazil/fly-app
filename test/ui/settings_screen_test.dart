import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/config_groups.dart';
import 'package:fly_app/state/config_editor.dart';
import 'package:fly_app/ui/settings_screen.dart';

const power = PowerConfig(
  capacityMah: 20000,
  minVoltageMv: 42000,
  maxVoltageMv: 58800,
  powerControlEnabled: true,
  voltageDividerRatio: 11.05,
);

const thermal = ThermalConfig(
  motorReductionStartC: 80,
  motorMaxC: 100,
  escReductionStartC: 70,
  escMaxC: 95,
  motorTempSource: 0,
);

Widget wrap(Widget child) => MaterialApp(home: child);

/// Records saves without touching a session.
class RecordingEditor implements ConfigEditor {
  final saves = <String>[];
  SaveOutcome outcome = const SaveOk();

  @override
  bool get authenticated => true;

  @override
  Future<SaveOutcome> savePower(PowerConfig c, {String? pin}) async {
    saves.add('power');
    return outcome;
  }

  @override
  Future<SaveOutcome> saveThermal(ThermalConfig c, {String? pin}) async {
    saves.add('thermal');
    return outcome;
  }
}

void main() {
  late RecordingEditor editor;

  setUp(() => editor = RecordingEditor());

  SettingsScreen screen({
    bool armed = false,
    bool selectableMotorSource = false,
  }) =>
      SettingsScreen(
        editor: editor,
        power: power,
        thermal: thermal,
        armed: armed,
        selectableMotorTempSource: selectableMotorSource,
      );

  testWidgets('shows the current values in the units a pilot thinks in',
      (tester) async {
    await tester.pumpWidget(wrap(screen()));

    expect(find.text('20000'), findsOneWidget, reason: 'mAh');
    expect(find.text('42.0'), findsOneWidget, reason: 'volts, not millivolts');
    expect(find.text('58.8'), findsOneWidget);
    expect(find.text('80'), findsOneWidget, reason: '°C, not millicelsius');
  });

  testWidgets('the motor source control is absent without the capability',
      (tester) async {
    await tester.pumpWidget(wrap(screen(selectableMotorSource: false)));
    expect(find.text('Origem da temperatura do motor'), findsNothing);

    await tester.pumpWidget(wrap(screen(selectableMotorSource: true)));
    expect(find.text('Origem da temperatura do motor'), findsOneWidget);
  });

  group('the save button', () {
    Finder saveThermal() => find.byKey(const Key('save-thermal'));

    Future<void> typeInto(WidgetTester tester, Key key, String text) async {
      await tester.enterText(find.byKey(key), text);
      await tester.pump();
    }

    testWidgets('is live for a valid group', (tester) async {
      await tester.pumpWidget(wrap(screen()));
      // The form is taller than the default 800x600 test viewport, so the
      // button has to be scrolled to before it can be tapped -- exactly what
      // a pilot does. Without this, tap() hits empty space and the assertion
      // fails for a reason that has nothing to do with the button.
      await tester.ensureVisible(saveThermal());
      await tester.pumpAndSettle();
      await tester.tap(saveThermal());
      await tester.pump();
      expect(editor.saves, ['thermal']);
    });

    testWidgets('goes inert when the reduction start reaches the maximum',
        (tester) async {
      await tester.pumpWidget(wrap(screen()));
      await typeInto(tester, const Key('motor-start'), '100');

      expect(
        tester.widget<ElevatedButton>(saveThermal()).onPressed,
        isNull,
        reason: 'equal values make the firmware cut power outright',
      );
      expect(find.textContaining('precisa ser menor'), findsOneWidget);
    });

    testWidgets('goes inert for an inverted pair', (tester) async {
      await tester.pumpWidget(wrap(screen()));
      await typeInto(tester, const Key('motor-start'), '110');
      expect(tester.widget<ElevatedButton>(saveThermal()).onPressed, isNull);
    });

    testWidgets('goes inert for a value outside the firmware range',
        (tester) async {
      await tester.pumpWidget(wrap(screen()));
      await typeInto(tester, const Key('motor-max'), '200');
      expect(tester.widget<ElevatedButton>(saveThermal()).onPressed, isNull);
      expect(find.textContaining('0 a 150'), findsOneWidget);
    });

    testWidgets('is inert while the aircraft is armed, with the reason shown',
        (tester) async {
      await tester.pumpWidget(wrap(screen(armed: true)));

      expect(tester.widget<ElevatedButton>(saveThermal()).onPressed, isNull);
      // "aeronave" is feminine, so the screen says "armada". The word in the
      // plan was wrong, not the screen: shipping "armado" here would be a
      // grammatical error in front of a Brazilian pilot.
      //
      // findsWidgets, not findsOneWidget: each group carries its own notice
      // beside its own disabled button, which is where the reason belongs.
      // Pinning the count would break when a third group arrives, for a
      // reason that has nothing to do with what this test is about.
      expect(find.textContaining('armada'), findsWidgets);
    });

    testWidgets('arming while the screen is open disables it', (tester) async {
      await tester.pumpWidget(wrap(screen(armed: false)));
      expect(
          tester.widget<ElevatedButton>(saveThermal()).onPressed, isNotNull);

      await tester.pumpWidget(wrap(screen(armed: true)));
      expect(tester.widget<ElevatedButton>(saveThermal()).onPressed, isNull);
    });
  });

  group('outcomes', () {
    testWidgets('a wrong PIN says so', (tester) async {
      editor.outcome = const SaveWrongPin();
      await tester.pumpWidget(wrap(screen()));
      await tester.ensureVisible(find.byKey(const Key('save-thermal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-thermal')));
      await tester.pumpAndSettle();

      expect(find.textContaining('PIN'), findsWidgets);
    });

    testWidgets('a controller rejection names the divergence, not the pilot',
        (tester) async {
      editor.outcome = const SaveRejectedByController();
      await tester.pumpWidget(wrap(screen()));
      await tester.ensureVisible(find.byKey(const Key('save-thermal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-thermal')));
      await tester.pumpAndSettle();

      expect(find.textContaining('controlador recusou'), findsOneWidget);
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

        await tester.pumpWidget(wrap(screen(selectableMotorSource: true)));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });
}
