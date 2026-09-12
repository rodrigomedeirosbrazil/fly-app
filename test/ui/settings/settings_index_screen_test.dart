import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ui/settings/settings_index_screen.dart';

Widget wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('lists the four areas the portal has', (tester) async {
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
      onOpenBms: () {},
      onOpenSystem: () {},
    )));

    expect(find.text('Energia'), findsOneWidget);
    expect(find.text('Térmica'), findsOneWidget);
    expect(find.text('BMS'), findsOneWidget);
    expect(find.text('Sistema'), findsOneWidget);
  });

  testWidgets('all four areas open', (tester) async {
    var power = false;
    var thermal = false;
    var bms = false;
    var system = false;
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () => power = true,
      onOpenThermal: () => thermal = true,
      onOpenBms: () => bms = true,
      onOpenSystem: () => system = true,
    )));

    await tester.tap(find.text('Energia'));
    await tester.pumpAndSettle();
    expect(power, isTrue);

    await tester.tap(find.text('Térmica'));
    await tester.pumpAndSettle();
    expect(thermal, isTrue);

    await tester.tap(find.text('BMS'));
    await tester.pumpAndSettle();
    expect(bms, isTrue);

    await tester.tap(find.text('Sistema'));
    await tester.pumpAndSettle();
    expect(system, isTrue);
  });

  testWidgets('all four cards have descriptions', (tester) async {
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
      onOpenBms: () {},
      onOpenSystem: () {},
    )));

    expect(find.textContaining('Capacidade da bateria'), findsOneWidget);
    expect(find.textContaining('Limites de proteção'), findsOneWidget);
    expect(find.textContaining('Tipo de BMS'), findsOneWidget);
    expect(find.textContaining('Volume do buzzer'), findsOneWidget);
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

        await tester.pumpWidget(wrap(SettingsIndexScreen(
          onOpenPower: () {},
          onOpenThermal: () {},
          onOpenBms: () {},
          onOpenSystem: () {},
        )));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });
}
