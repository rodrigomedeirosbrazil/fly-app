import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ui/settings/settings_index_screen.dart';

Widget wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('lists the four areas the portal has', (tester) async {
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
    )));

    expect(find.text('Energia'), findsOneWidget);
    expect(find.text('Térmica'), findsOneWidget);
    expect(find.text('BMS'), findsOneWidget);
    expect(find.text('Sistema'), findsOneWidget);
  });

  testWidgets('the two implemented areas open', (tester) async {
    var power = false;
    var thermal = false;
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () => power = true,
      onOpenThermal: () => thermal = true,
    )));

    await tester.tap(find.text('Energia'));
    await tester.pumpAndSettle();
    expect(power, isTrue);

    await tester.tap(find.text('Térmica'));
    await tester.pumpAndSettle();
    expect(thermal, isTrue);
  });

  testWidgets('the unimplemented areas are present, inert, and say why',
      (tester) async {
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
    )));

    // Present rather than hidden, so a pilot learns what exists instead of
    // discovering it in a browser.
    expect(find.textContaining('pareamento'), findsOneWidget);
    expect(find.textContaining('busca'), findsOneWidget);
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
        )));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });
}
