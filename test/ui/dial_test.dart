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

  group('the reduction band', () {
    // The band is painted, so these assert on the painter's inputs rather
    // than on pixels: a CustomPainter's fields are the contract here.
    _DialPainterProbe probe(WidgetTester tester) {
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(Dial),
          matching: find.byType(CustomPaint),
        ).first,
      );
      final painter = paint.painter!;
      return _DialPainterProbe(
        start: (painter as dynamic).bandStartFraction as double?,
        end: (painter as dynamic).bandEndFraction as double?,
      );
    }

    testWidgets('is absent when no thresholds are known', (tester) async {
      await tester.pumpWidget(wrap(const Dial(
        value: 61,
        max: 140,
        unit: '°C',
      )));
      expect(probe(tester).start, isNull);
    });

    testWidgets('spans start to end as a fraction of the fixed scale',
        (tester) async {
      await tester.pumpWidget(wrap(const Dial(
        value: 61,
        max: 140,
        unit: '°C',
        bandStart: 70,
        bandEnd: 140,
      )));
      final p = probe(tester);
      expect(p.start, closeTo(0.5, 1e-9));
      expect(p.end, closeTo(1.0, 1e-9));
    });

    testWidgets('a maximum beyond the scale runs to the end of the arc',
        (tester) async {
      await tester.pumpWidget(wrap(const Dial(
        value: 61,
        max: 140,
        unit: '°C',
        bandStart: 70,
        bandEnd: 200,
      )));
      expect(probe(tester).end, closeTo(1.0, 1e-9),
          reason: 'clamped, never drawn off the arc');
    });

    testWidgets('numbers that do not form a range draw nothing',
        (tester) async {
      for (final (start, end) in [(0.0, 0.0), (100.0, 100.0), (110.0, 100.0)]) {
        await tester.pumpWidget(wrap(Dial(
          value: 61,
          max: 140,
          unit: '°C',
          bandStart: start,
          bandEnd: end,
        )));
        expect(probe(tester).start, isNull, reason: '$start to $end');
      }
    });

    testWidgets('a band does not require a value', (tester) async {
      // A missing sensor still has configured thresholds.
      await tester.pumpWidget(wrap(const Dial(
        value: null,
        max: 140,
        unit: '°C',
        bandStart: 70,
        bandEnd: 140,
      )));
      expect(probe(tester).start, closeTo(0.5, 1e-9));
      expect(find.text('–'), findsOneWidget);
    });
  });
}

class _DialPainterProbe {
  const _DialPainterProbe({required this.start, required this.end});
  final double? start;
  final double? end;
}
