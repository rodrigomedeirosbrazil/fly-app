import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ui/widgets/bar_gauge.dart';
import 'package:fly_app/ui/widgets/dial.dart';

Widget wrap(Widget child, {double width = 120, double height = 120}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );

/// The fill's share of the track, read from the widget the bar paints with.
double? fillFraction(WidgetTester t) {
  final f = find.byKey(const Key('bar-fill'));
  if (f.evaluate().isEmpty) return null;
  return t.widget<FractionallySizedBox>(f).widthFactor;
}

void main() {
  testWidgets('caption, number and unit', (tester) async {
    await tester.pumpWidget(wrap(
      BarGauge(
        value: 7.5,
        max: 18,
        unit: 'kW',
        caption: 'POTÊNCIA',
        format: (v) => v.toStringAsFixed(1),
      ),
    ));
    expect(find.text('POTÊNCIA'), findsOneWidget);
    expect(find.text('7.5'), findsOneWidget);
    expect(find.text('kW'), findsOneWidget);
  });

  testWidgets('the number is much larger than the caption', (tester) async {
    // The point of the card: the reading, not its name, is what the pilot
    // sees at a glance.
    await tester.pumpWidget(wrap(
      const BarGauge(value: 5830, max: 6000, unit: '', caption: 'RPM'),
    ));
    final number = tester.getSize(find.text('5830')).height;
    final caption = tester.getSize(find.text('RPM')).height;
    expect(number, greaterThan(caption * 2.5));
  });

  testWidgets('the fill is the value\'s share of the scale', (tester) async {
    await tester.pumpWidget(wrap(
      const BarGauge(value: 50.4, min: 42, max: 58.8, unit: 'V'),
    ));
    expect(fillFraction(tester), closeTo(0.5, 1e-9));
  });

  testWidgets('out-of-scale values clamp, the number does not', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(
      const BarGauge(value: 320, max: 300, unit: 'A'),
    ));
    expect(fillFraction(tester), 1.0);
    expect(find.text('320'), findsOneWidget);

    await tester.pumpWidget(wrap(
      const BarGauge(value: -12, max: 300, unit: 'A'),
    ));
    expect(fillFraction(tester), 0.0);
    expect(find.text('-12'), findsOneWidget);
  });

  testWidgets('a null value is a dash with its reason and an empty track', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(
      const BarGauge(
        value: null,
        max: 6000,
        unit: 'kW',
        caption: 'RPM',
        note: 'SEM DADOS',
      ),
    ));
    expect(find.text('–'), findsOneWidget);
    expect(find.text('SEM DADOS'), findsOneWidget);
    expect(find.text('kW'), findsNothing);
    expect(find.text('RPM'), findsOneWidget);
    expect(find.byKey(const Key('bar-track')), findsOneWidget);
    expect(fillFraction(tester), isNull);
  });

  testWidgets('no bar draws no track, and keeps its slot', (tester) async {
    await tester.pumpWidget(wrap(
      BarGauge(
        value: 50.8,
        max: 1,
        unit: 'V',
        showBar: false,
        format: (v) => v.toStringAsFixed(1),
      ),
    ));
    expect(find.text('50.8'), findsOneWidget);
    expect(find.byKey(const Key('bar-track')), findsNothing);
    final withoutBar = tester.getTopLeft(find.text('50.8'));

    await tester.pumpWidget(wrap(
      BarGauge(
        value: 50.8,
        max: 60,
        unit: 'V',
        format: (v) => v.toStringAsFixed(1),
      ),
    ));
    // The number does not move when the scale arrives.
    expect(tester.getTopLeft(find.text('50.8')), withoutBar);
  });

  testWidgets('a scale with no width draws no track', (tester) async {
    await tester.pumpWidget(wrap(
      const BarGauge(value: 3, min: 5, max: 5, unit: 'V'),
    ));
    expect(find.byKey(const Key('bar-track')), findsNothing);
  });

  testWidgets('stripes sit at their values, the fill takes the colour', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(
      const BarGauge(
        value: 45,
        min: 40,
        max: 60,
        unit: 'V',
        color: Colors.amber,
        stripes: [DialStripe(42, Colors.amber), DialStripe(41, Colors.red)],
      ),
    ));
    final track = tester.getRect(find.byKey(const Key('bar-track')));
    final centres = [
      for (final i in [0, 1])
        tester.getCenter(find.byKey(Key('bar-stripe-$i'))).dx - track.left,
    ];
    expect(centres[0], closeTo(track.width * 0.10, 1.5));
    expect(centres[1], closeTo(track.width * 0.05, 1.5));
    final fill = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const Key('bar-fill')),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect((fill.decoration as BoxDecoration).color, Colors.amber);
  });

  testWidgets('a long number shrinks instead of overflowing', (tester) async {
    // A widget test fails on overflow, so pumping narrow is the assertion.
    await tester.pumpWidget(wrap(
      const BarGauge(value: 12345678, max: 6000, unit: 'kW', caption: 'RPM'),
      width: 80,
      height: 80,
    ));
    expect(tester.takeException(), isNull);
  });
}
