import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ble/fly_controller_link.dart';
import 'package:fly_app/ui/connection_screen.dart';

Widget wrap(
  LinkStatus status, {
  int rejectedFrames = 0,
  VoidCallback? onConnect,
  VoidCallback? onCancel,
}) =>
    MaterialApp(
      home: ConnectionScreen(
        status: status,
        rejectedFrames: rejectedFrames,
        onConnect: onConnect ?? () {},
        onCancel: onCancel ?? () {},
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
      for (final status in const [LinkStatus.idle, LinkStatus.scanning]) {
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
