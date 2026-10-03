import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/state/app_update_policy.dart';
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
      onOpenLogs: () {},
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
    var logs = false;
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () => power = true,
      onOpenThermal: () => thermal = true,
      onOpenBms: () => bms = true,
      onOpenSystem: () => system = true,
      onOpenFirmware: () => firmware = true,
      onOpenLogs: () => logs = true,
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

    await tester.scrollUntilVisible(find.text('Registros de voo'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Registros de voo'));
    await tester.pumpAndSettle();
    expect(logs, isTrue);
  });

  testWidgets('all five cards have descriptions', (tester) async {
    await tester.pumpWidget(wrap(SettingsIndexScreen(
      onOpenPower: () {},
      onOpenThermal: () {},
      onOpenBms: () {},
      onOpenSystem: () {},
      onOpenFirmware: () {},
      onOpenLogs: () {},
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
          onOpenLogs: () {},
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
      onOpenLogs: () {},
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
      onOpenLogs: () {},
    )));

    expect(find.text('Firmware desconhecido'), findsOneWidget);
  });

  group('app version card', () {
    Future<void> pumpIndex(
      WidgetTester tester, {
      String? appVersion = '2026-10-03.1',
      UpdateAvailability appUpdate = const UpdateUnknown(),
      bool appUpdateChecking = false,
      VoidCallback? onOpenRelease,
    }) async {
      await tester.pumpWidget(wrap(SettingsIndexScreen(
        onOpenPower: () {},
        onOpenThermal: () {},
        onOpenBms: () {},
        onOpenSystem: () {},
        onOpenFirmware: () {},
        onOpenLogs: () {},
        appVersion: appVersion,
        appUpdate: appUpdate,
        appUpdateChecking: appUpdateChecking,
        onOpenRelease: onOpenRelease,
      )));
      await tester.scrollUntilVisible(find.text('VERSÃO DO APP'), 100);
      // scrollUntilVisible stops as soon as the first pixel of the label is
      // built, which can still be below the viewport edge. Without this the
      // taps below miss and "does nothing" passes for the wrong reason.
      await tester.ensureVisible(find.text('VERSÃO DO APP'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the installed version, up to date', (tester) async {
      await pumpIndex(tester, appUpdate: const UpToDate());
      expect(find.text('2026-10-03.1'), findsOneWidget);
      expect(find.text('Atualizado'), findsOneWidget);
    });

    testWidgets('says it is checking while the network has not answered',
        (tester) async {
      await pumpIndex(tester, appUpdateChecking: true);
      expect(find.text('Verificando…'), findsOneWidget);
    });

    testWidgets('says it could not check once the check is over',
        (tester) async {
      await pumpIndex(tester);
      expect(find.text('Não foi possível verificar'), findsOneWidget);
    });

    testWidgets('a build without a number says so and checks nothing',
        (tester) async {
      await pumpIndex(tester, appVersion: null, appUpdateChecking: true);
      expect(find.text('Desconhecida'), findsOneWidget);
      expect(find.text('Build sem número de versão'), findsOneWidget);
    });

    testWidgets('an available release opens where it can be installed',
        (tester) async {
      var opened = 0;
      await pumpIndex(
        tester,
        appUpdate: const UpdateAvailable('2026-10-04.1'),
        onOpenRelease: () => opened++,
      );

      expect(find.text('Nova versão 2026-10-04.1 — toque para baixar'),
          findsOneWidget);
      await tester.tap(find.text('VERSÃO DO APP'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('where it cannot be installed, the card says how',
        (tester) async {
      await pumpIndex(
        tester,
        appUpdate: const UpdateAvailable('2026-10-04.1'),
      );
      expect(find.text('Nova versão 2026-10-04.1 — reinstale pelo Mac'),
          findsOneWidget);
    });

    testWidgets('up to date, tapping does nothing', (tester) async {
      var opened = 0;
      await pumpIndex(
        tester,
        appUpdate: const UpToDate(),
        onOpenRelease: () => opened++,
      );
      await tester.tap(find.text('VERSÃO DO APP'));
      await tester.pumpAndSettle();
      expect(opened, 0);
    });

    testWidgets('a notice that cannot be opened is neither cut off nor dimmed',
        (tester) async {
      // iOS: no callback, so the card is inert -- but the notice is the one
      // thing on it worth reading, and "reinstale pelo Mac" is its tail.
      //
      // 480 wide, not a phone's 320-390: flutter_test renders in Ahem, where
      // every glyph is a full 14px square, so this 45-character line is
      // ~630px and word wrap needs three lines at any phone width. Real
      // Roboto is about half that, so on a 320px phone the notice wraps to
      // two lines for real. At 480 Ahem reproduces that same two-line fit,
      // and at one line it still overflows -- which is what is pinned.
      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpIndex(
        tester,
        appUpdate: const UpdateAvailable('2026-10-04.1'),
      );

      final notice = find.text('Nova versão 2026-10-04.1 — reinstale pelo Mac');
      expect(tester.renderObject<RenderParagraph>(notice).didExceedMaxLines,
          isFalse,
          reason: 'the actionable tail must not be hidden by an ellipsis');
      expect(tester.widget<Text>(notice).style!.color,
          Theme.of(tester.element(notice)).colorScheme.onSurface,
          reason: 'a notice is not a disabled card');
    });
  });
}
