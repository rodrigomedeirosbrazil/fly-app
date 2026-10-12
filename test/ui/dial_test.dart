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
    expect(find.text('BATERIA'), findsOneWidget);
    expect(find.text('BATERIA %'), findsNothing);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
  });

  testWidgets('no scale ends unless asked', (tester) async {
    await tester.pumpWidget(wrap(
      const Dial(value: 61, max: 140, unit: '°C', caption: 'MOTOR'),
    ));

    expect(find.text('140'), findsNothing);
  });

  group('stripes and colour', () {
    // Painted, so these read the painter's inputs: its fields are the contract.
    dynamic painter(WidgetTester tester) => tester
        .widget<CustomPaint>(find
            .descendant(of: find.byType(Dial), matching: find.byType(CustomPaint))
            .first)
        .painter;

    testWidgets('stripes sit at their values as fractions of the scale',
        (tester) async {
      await tester.pumpWidget(wrap(const Dial(
        value: 61,
        max: 140,
        unit: '°C',
        stripes: [
          DialStripe(70, Colors.amber),
          DialStripe(105, Colors.red),
        ],
      )));
      final p = painter(tester);
      expect(p.stripeFractions as List<double>, [0.5, 0.75]);
      expect(p.stripeColors as List<Color>, [Colors.amber, Colors.red]);
    });

    testWidgets('the whole arc takes the given colour', (tester) async {
      await tester.pumpWidget(wrap(const Dial(
        value: 90,
        max: 140,
        unit: '°C',
        color: Colors.amber,
      )));
      expect(painter(tester).valueColor as Color, Colors.amber);
    });

    testWidgets('a scale that does not start at zero', (tester) async {
      await tester.pumpWidget(wrap(const Dial(
        value: 50.4,
        min: 42,
        max: 58.8,
        unit: 'V',
      )));
      expect(painter(tester).fraction as double, closeTo(0.5, 1e-9));
    });

    testWidgets('out-of-scale values clamp, the number does not',
        (tester) async {
      await tester.pumpWidget(wrap(Dial(
        value: -12,
        max: 300,
        unit: 'A',
        format: (v) => v.round().toString(),
      )));
      expect(painter(tester).fraction as double, 0.0);
      expect(find.text('-12'), findsOneWidget);

      await tester.pumpWidget(wrap(Dial(
        value: 320,
        max: 300,
        unit: 'A',
        format: (v) => v.round().toString(),
      )));
      expect(painter(tester).fraction as double, 1.0);
      expect(find.text('320'), findsOneWidget);
    });

    testWidgets('no arc shows the number alone', (tester) async {
      await tester.pumpWidget(wrap(Dial(
        value: 50.8,
        max: 1,
        unit: 'V',
        showArc: false,
        format: (v) => v.toStringAsFixed(1),
      )));
      expect(painter(tester).showArc as bool, isFalse);
      expect(find.text('50.8'), findsOneWidget);
    });

    testWidgets('a scale with no width draws no arc', (tester) async {
      await tester.pumpWidget(wrap(const Dial(
        value: 3,
        min: 5,
        max: 5,
        unit: 'V',
      )));
      expect(painter(tester).showArc as bool, isFalse);
    });
  });
}
