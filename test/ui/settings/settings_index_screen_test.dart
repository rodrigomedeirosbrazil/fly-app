import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ui/settings/settings_index_screen.dart';

Widget wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('lists the five settings areas', (tester) async {
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
      onOpenBms: () {},
      onOpenSystem: () {},
      onOpenFirmware: () {},
    )));

    expect(find.text('Energia'), findsOneWidget);
    expect(find.text('Térmica'), findsOneWidget);
    expect(find.text('BMS'), findsOneWidget);
    expect(find.text('Sistema'), findsOneWidget);
    // Scrolled to, not assumed visible: a ListView builds only what is on
    // screen, and five cards do not fit the 600px test surface. The claim
    // here is that the five areas are listed, not that they fit at once.
    await tester.scrollUntilVisible(find.text('Atualizar'), 100);
    expect(find.text('Atualizar'), findsOneWidget);
  });

  testWidgets('all five areas open', (tester) async {
    var power = false;
    var thermal = false;
    var bms = false;
    var system = false;
    var firmware = false;
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () => power = true,
      onOpenThermal: () => thermal = true,
      onOpenBms: () => bms = true,
      onOpenSystem: () => system = true,
      onOpenFirmware: () => firmware = true,
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

    // scrollUntilVisible, not ensureVisible: the latter needs the widget
    // already in the tree, and a ListView has not built the card that is
    // still off screen.
    await tester.scrollUntilVisible(find.text('Atualizar'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atualizar'));
    await tester.pumpAndSettle();
    expect(firmware, isTrue);
  });

  testWidgets('all five cards have descriptions', (tester) async {
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
      onOpenBms: () {},
      onOpenSystem: () {},
      onOpenFirmware: () {},
    )));

    expect(find.textContaining('Capacidade da bateria'), findsOneWidget);
    expect(find.textContaining('Limites de proteção'), findsOneWidget);
    expect(find.textContaining('Tipo de BMS'), findsOneWidget);
    expect(find.textContaining('Volume do buzzer'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.textContaining('Enviar novo firmware'), 100);
    expect(find.textContaining('Enviar novo firmware'), findsOneWidget);
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
          onOpenFirmware: () {},
        )));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('names the firmware the controller is running', (tester) async {
    // The web portal shows this on its front page. In the app it lived only
    // in the update screen and the flight-screen drawer, so "which firmware
    // is on this aircraft" meant opening the screen that replaces it.
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
      onOpenBms: () {},
      onOpenSystem: () {},
      onOpenFirmware: () {},
      firmwareVersion: '2.4.1 · Tmotor',
    )));

    expect(find.text('Firmware 2.4.1 · Tmotor'), findsOneWidget);
  });

  testWidgets('says so when the version is unknown', (tester) async {
    // The `$XCTOD` path never reads INFO. Blank space would read as a
    // rendering fault rather than as a missing reading.
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
      onOpenBms: () {},
      onOpenSystem: () {},
      onOpenFirmware: () {},
    )));

    expect(find.text('Firmware desconhecido'), findsOneWidget);
  });
}
