import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/ui/connection_screen.dart';

Widget wrap(
  LinkStatus status, {
  int rejectedFrames = 0,
  VoidCallback? onConnect,
  VoidCallback? onCancel,
  VoidCallback? onOpenSettings,
  VoidCallback? onOpenLocationSettings,
}) =>
    MaterialApp(
      home: ConnectionScreen(
        status: status,
        rejectedFrames: rejectedFrames,
        onConnect: onConnect ?? () {},
        onCancel: onCancel ?? () {},
        onOpenSettings: onOpenSettings ?? () {},
        onOpenLocationSettings: onOpenLocationSettings ?? () {},
      ),
    );

void main() {
  testWidgets('at rest it offers Conectar and shows no progress',
      (tester) async {
    await tester.pumpWidget(wrap(LinkStatus.idle));

    expect(find.text('Conectar'), findsOneWidget);
    expect(find.text('Cancelar'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('tapping Conectar starts the radio', (tester) async {
    var started = 0;
    await tester.pumpWidget(wrap(LinkStatus.idle, onConnect: () => started++));

    await tester.tap(find.text('Conectar'));
    await tester.pump();

    expect(started, 1);
  });

  testWidgets('while trying, the button becomes the way out', (tester) async {
    await tester.pumpWidget(wrap(LinkStatus.scanning));
    await tester.pump();

    expect(find.text('Cancelar'), findsOneWidget);
    expect(find.text('Conectar'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Procurando o controlador…'), findsOneWidget);
  });

  testWidgets('tapping Cancelar stops the radio', (tester) async {
    var cancelled = 0;
    await tester.pumpWidget(
      wrap(LinkStatus.scanning, onCancel: () => cancelled++),
    );
    await tester.pump();

    await tester.tap(find.text('Cancelar'));
    await tester.pump();

    expect(cancelled, 1);
  });

  testWidgets('a lost link says so and keeps offering the way out',
      (tester) async {
    await tester.pumpWidget(wrap(LinkStatus.disconnected));
    await tester.pump();

    expect(find.text('Conexão perdida. Tentando de novo…'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
  });

  group('discarded frames', () {
    // Non-zero here with no telemetry is the signature of an ATT MTU that
    // never grew past 23 bytes on Android. That failure is the one that
    // prevents leaving this screen, so this is where it has to be visible.
    testWidgets('are hidden at zero', (tester) async {
      await tester.pumpWidget(wrap(LinkStatus.scanning));
      await tester.pump();

      expect(find.textContaining('descartados'), findsNothing);
    });

    testWidgets('are counted when they happen', (tester) async {
      await tester.pumpWidget(wrap(LinkStatus.scanning, rejectedFrames: 7));
      await tester.pump();

      expect(find.text('7 quadros descartados'), findsOneWidget);
    });
  });

  group('a refused permission', () {
    // Android can refuse permanently, in which case asking again does
    // nothing and the only way out of the app is Settings.
    testWidgets('says what happened and offers Settings', (tester) async {
      await tester.pumpWidget(wrap(LinkStatus.unauthorized));

      expect(find.text('Permissão de Bluetooth negada'), findsOneWidget);
      expect(find.text('Abrir Ajustes'), findsOneWidget);
      // Not a connection attempt: no spinner, and retrying is still offered.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Conectar'), findsOneWidget);
    });

    testWidgets('the Settings button is wired', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        wrap(LinkStatus.unauthorized, onOpenSettings: () => opened++),
      );

      await tester.tap(find.text('Abrir Ajustes'));
      await tester.pump();

      expect(opened, 1);
    });
  });

  group('a precondition the pilot has to fix', () {
    // Neither of these was a state before. A disabled adapter meant a mute
    // retry loop on iOS, and below API 31 permission_handler reported
    // "denied" for a Bluetooth that was merely off.
    testWidgets('Bluetooth off says so and still offers Conectar',
        (tester) async {
      await tester.pumpWidget(wrap(LinkStatus.bluetoothOff));

      expect(find.text('Bluetooth desligado'), findsOneWidget);
      // Not an attempt: no spinner, and the door stays open.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Conectar'), findsOneWidget);
      expect(find.text('Cancelar'), findsNothing);
    });

    testWidgets('location off offers the system location settings',
        (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        wrap(LinkStatus.locationOff, onOpenLocationSettings: () => opened++),
      );

      expect(find.text('Localização desligada'), findsOneWidget);
      expect(find.text('Conectar'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.text('Abrir Localização'));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets('neither offers the app-settings button', (tester) async {
      // The app's own settings page cannot toggle either one, so offering it
      // would send the pilot somewhere useless.
      await tester.pumpWidget(wrap(LinkStatus.bluetoothOff));
      expect(find.text('Abrir Ajustes'), findsNothing);

      await tester.pumpWidget(wrap(LinkStatus.locationOff));
      expect(find.text('Abrir Ajustes'), findsNothing);
    });

    testWidgets('Bluetooth off offers no button at all', (tester) async {
      // The pilot flips the adapter from the shade; a second route would be
      // noise on a screen that reserves exactly one action slot.
      await tester.pumpWidget(wrap(LinkStatus.bluetoothOff));
      expect(find.byType(TextButton), findsNothing);
    });
  });

  group('layout holds at real device sizes', () {
    // A widget test fails on RenderFlex overflow, so pumping at each size is
    // the assertion. Same four sizes as flight_screen_test.dart. Both modes
    // are pumped because the trying mode is the taller of the two.
    for (final size in const [
      Size(393, 852),
      Size(320, 480),
      Size(852, 393),
      Size(1280, 800),
    ]) {
      for (final status in const [
        LinkStatus.idle,
        LinkStatus.scanning,
        LinkStatus.unauthorized,
        LinkStatus.bluetoothOff,
        LinkStatus.locationOff,
      ]) {
        testWidgets('${size.width.toInt()}x${size.height.toInt()} ${status.name}',
            (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(wrap(status, rejectedFrames: 12));
          // Not pumpAndSettle: the progress indicator never settles.
          await tester.pump();

          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
