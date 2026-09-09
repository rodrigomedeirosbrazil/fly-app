import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/ui/widgets/dial.dart';

Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 200, height: 200, child: child))),
    );

void main() {
  testWidgets('shows the value and unit when present', (tester) async {
    await tester.pumpWidget(wrap(
      const Dial(label: 'MOTOR', value: 61, max: 120, unit: '°C'),
    ));

    expect(find.text('61'), findsOneWidget);
    expect(find.text('°C'), findsOneWidget);
    expect(find.text('MOTOR'), findsOneWidget);
  });

  testWidgets('shows a dash and no unit when the value is null', (tester) async {
    await tester.pumpWidget(wrap(
      const Dial(label: 'MOTOR', value: null, max: 120, unit: '°C'),
    ));

    expect(find.text('–'), findsOneWidget);
    expect(find.text('°C'), findsNothing);
    expect(find.text('MOTOR'), findsOneWidget);
  });

  testWidgets('renders a badge when one is given', (tester) async {
    await tester.pumpWidget(wrap(
      const Dial(label: 'MOTOR', value: 61, max: 120, unit: '°C', badge: 'CAN'),
    ));

    expect(find.text('CAN'), findsOneWidget);
  });
}
