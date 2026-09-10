import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ui/widgets/dial.dart';

Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 220, height: 220, child: child)),
      ),
    );

void main() {
  testWidgets('the unit sits beside the number, not on its own line',
      (tester) async {
    await tester.pumpWidget(wrap(
      const Dial(value: 61, max: 140, unit: '°C', caption: 'MOTOR'),
    ));

    expect(find.text('61'), findsOneWidget);
    expect(find.text('°C'), findsOneWidget);
    expect(find.text('MOTOR'), findsOneWidget);
  });

  testWidgets('a null value is a dash with no unit, caption intact',
      (tester) async {
    await tester.pumpWidget(wrap(
      const Dial(value: null, max: 140, unit: '°C', caption: 'MOTOR'),
    ));

    expect(find.text('–'), findsOneWidget);
    expect(find.text('°C'), findsNothing);
    // The caption is the band's structure, not a reading: it stays put so the
    // dial does not change shape when a sensor drops.
    expect(find.text('MOTOR'), findsOneWidget);
  });

  testWidgets('a provenance badge renders inside the ring', (tester) async {
    await tester.pumpWidget(wrap(
      const Dial(value: 61, max: 140, unit: '°C', caption: 'MOTOR', badge: 'CAN'),
    ));

    expect(find.text('CAN'), findsOneWidget);
  });

  testWidgets('an inner label carries the unit and the scale ends',
      (tester) async {
    await tester.pumpWidget(wrap(
      const Dial(value: 68, max: 100, unit: '%', label: 'BATERIA', showScale: true),
    ));

    expect(find.text('68'), findsOneWidget);
    expect(find.text('BATERIA %'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
  });

  testWidgets('no scale ends unless asked', (tester) async {
    await tester.pumpWidget(wrap(
      const Dial(value: 61, max: 140, unit: '°C', caption: 'MOTOR'),
    ));

    expect(find.text('140'), findsNothing);
  });
}
