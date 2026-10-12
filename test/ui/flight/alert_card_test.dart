import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/state/flight_alerts.dart';
import 'package:fly_app/ui/flight/alert_card.dart';

Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 120, height: 130, child: child)),
      ),
    );

const reducing = FlightAlert(
  component: AlertComponent.motor,
  problem: AlertProblem.reducing,
  severity: AlertSeverity.caution,
  rank: 4,
  powerPct: 70,
);
const near = FlightAlert(
  component: AlertComponent.esc,
  problem: AlertProblem.nearLimit,
  severity: AlertSeverity.info,
  rank: 10,
  marginC: 5,
);

void main() {
  testWidgets('no alerts with a frame is NENHUM ALERTA', (tester) async {
    await tester.pumpWidget(
        wrap(const AlertCard(alerts: [], hasFrame: true)));
    expect(find.text('NENHUM'), findsOneWidget);
    expect(find.text('ALERTA'), findsOneWidget);
    expect(find.text('ALERTAS'), findsNothing);
  });

  testWidgets('no frame is never an all-clear', (tester) async {
    await tester.pumpWidget(
        wrap(const AlertCard(alerts: [], hasFrame: false)));
    expect(find.text('NENHUM'), findsNothing);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
    expect(find.text('–'), findsOneWidget);
  });

  testWidgets('shows the first alert and counts the rest', (tester) async {
    await tester.pumpWidget(
        wrap(const AlertCard(alerts: [reducing, near], hasFrame: true)));
    expect(find.text('MOTOR'), findsOneWidget);
    expect(find.text('POTÊNCIA REDUZIDA'), findsOneWidget);
    expect(find.text('ESC'), findsNothing);
    expect(
      tester.widget<Text>(find.descendant(
          of: find.byKey(const Key('alert-more')), matching: find.byType(Text))),
      isA<Text>().having((t) => t.data, 'data', '+1'),
    );
  });

  testWidgets('a single alert has no count', (tester) async {
    await tester.pumpWidget(
        wrap(const AlertCard(alerts: [reducing], hasFrame: true)));
    expect(find.byKey(const Key('alert-more')), findsNothing);
  });

  testWidgets('tapping it calls back', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(AlertCard(
        alerts: const [reducing], hasFrame: true, onTap: () => taps++)));
    await tester.tap(find.byKey(const Key('alert-card')));
    expect(taps, 1);
  });

  testWidgets('fits a small phone cell without overflowing', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 80,
            height: 90,
            child: AlertCard(alerts: const [
              FlightAlert(
                component: AlertComponent.throttle,
                problem: AlertProblem.disarmed,
                severity: AlertSeverity.disarmed,
                rank: 1,
              ),
              near,
            ], hasFrame: true),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
